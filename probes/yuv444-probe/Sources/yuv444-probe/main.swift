import Foundation
import YUV444Core

// T-255: AVC444v2 packing probe (macOS side). See ../../README.md.
// Touches only the GPU (Metal compute) and the hardware HEVC encoder/decoder from the command line: no window, no
// display, no capture, no virtual display. Do not run it while a MateBridge stream is live (shared encoder engine).

let argv = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: yuv444-probe <command> [options]
  clips        [--size 2800x1840,1848x1214] [--frames 600] [--fps 60] [--main-mbps 40] [--aux-ratio 0.5]
               [--main-chroma box|pick] [--grain 14] [--out-dir DIR] [--no-png]  v2 clip pairs + reference PNGs (for T-254)
  pack-bench   [--size LIST] [--iters 400] [--content scroll]            M1: packer GPU time
  encode-bench [--size LIST] [--seconds 8] [--matrix | --views main|both --pace 0|60|120] [--content scroll]
               [--main-mbps 40] [--aux-ratio 0.5] [--main-chroma box]    M2: one vs two VT sessions, paced and unpaced
  quality      [--size 2800x1840] [--frames 600] [--fps 60] [--main-chroma box,pick] [--main-mbps 40] [--aux-ratio 0.5]
               [--samples 1] [--intra-quality 0.6,0.8] [--no-intra]     M3: bit cost by phase, PSNR vs 4:2:0 and 0033
  bitexact     [--size 1280x720]                                          M4: aux bit-exactness under colour tags
  preview      [--size 2800x1840] [--frame N] [--out PATH]                scene frame as PNG
"""

guard let command = argv.first else { print(usage); exit(2) }
let args = ProbeArgs(Array(argv.dropFirst()))
do {
    switch command {
    case "clips": try runClips(args)
    case "pack-bench": try runPackBench(args)
    case "encode-bench": try runEncodeBench(args)
    case "quality": try runQuality(args)
    case "bitexact": try runBitExact(args)
    case "preview": try runPreview(args)
    case "-h", "--help", "help": print(usage)
    default: print("unknown command '\(command)'\n\(usage)"); exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
