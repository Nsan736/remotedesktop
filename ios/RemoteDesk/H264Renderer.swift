import AVFoundation
import CoreMedia
import Foundation
import UIKit

final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()

    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var needsKeyframe = true
    private(set) var decodedFrames = 0

    init() {
        layer.videoGravity = .resize
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
    }

    func reset() {
        needsKeyframe = true
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.flush()
        } else {
            layer.flush()
        }
    }

    func feed(_ au: Data, isKeyframe: Bool) {
        var vcl: [Data] = []
        forEachNAL(in: au) { nal in
            let type = nal[nal.startIndex] & 0x1F
            switch type {
            case 7:
                if sps != nal { sps = nal; format = nil }
            case 8:
                if pps != nal { pps = nal; format = nil }
            case 1, 5:
                vcl.append(nal)
            default:
                break
            }
        }

        if format == nil {
            guard let s = sps, let p = pps else { return }
            format = makeFormat(s, p)
            needsKeyframe = true
        }
        guard let fmt = format, !vcl.isEmpty else { return }
        if needsKeyframe {
            if !isKeyframe { return }
            needsKeyframe = false
        }

        var avcc = Data(capacity: au.count + 16)
        for nal in vcl {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard let sample = makeSample(avcc, format: fmt) else { return }

        let failed: Bool
        if #available(iOS 17.0, *) {
            failed = layer.sampleBufferRenderer.status == .failed
        } else {
            failed = layer.status == .failed
        }
        if failed {
            reset()
            return
        }
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.enqueue(sample)
        } else {
            layer.enqueue(sample)
        }
        decodedFrames += 1
    }

    private func makeFormat(_ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress,
                      let pp = p.bindMemory(to: UInt8.self).baseAddress else { return }
                let ptrs: [UnsafePointer<UInt8>] = [sp, pp]
                let sizes: [Int] = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt)
            }
        }
        return fmt
    }

    private func makeSample(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = avcc.count
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleSize = count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func forEachNAL(in data: Data, _ body: (Data) -> Void) {
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var starts: [Int] = []
            var i = 0
            while i + 2 < n {
                if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                } else {
                    i += 1
                }
            }
            for (k, s) in starts.enumerated() {
                var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
                while e > s && b[e - 1] == 0 { e -= 1 }
                if e > s { ranges.append(s..<e) }
            }
        }
        for r in ranges {
            body(data.subdata(in: (data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound)))
        }
    }
}
