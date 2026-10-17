# TDMSReader
[![CI](https://github.com/DanBerge/TDMSReader.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/DanBerge/TDMSReader.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/DanBerge/TDMSReader.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/DanBerge/TDMSReader.jl)

Library to read National Instruments TDMS files in native Julia.

## Reading a whole file

```julia
using TDMSReader
f = readtdms("measurement.tdms")      # every group, channel and property
f.props                               # file properties
f["Group"].props                      # group properties
ch = f["Group", "Channel1"]           # or f[1, 1]
ch.data                               # the samples, as a Vector of the channel's type
ch.props                              # channel properties, e.g. "wf_increment"
```

`readtdms(path; memory)` refuses a file whose channel data would take more than
`memory` bytes (default: the free RAM) before reading any of it, and points to the
functions below.

## Reading on demand

```julia
info = tdmsinfo("measurement.tdms")   # the meta data only; no samples are read
ci = info["Group", "Channel1"]
ci.eltype, ci.nsamples                # element type and number of samples in the file

x = tdmsread(info, "Group", "Channel1", 1_000_001:2_000_000)   # a range, 1-based

tdmsblocks(info, "Group", "Channel1"; blocksize = 2^20) do x, offset
    # x: the next block of samples (one buffer, reused); offset: 0-based index of x[1]
end
```

`tdmsread` and `tdmsblocks` also accept the path in place of `info`. `tdmsblocks`
takes `memory`, a byte budget for its buffer, as well as `blocksize`; strings have
no fixed size, so a string channel takes `blocksize` only.
`TDMSReader.databytes(info)` is the number of bytes `readtdms` would allocate
(for a string, its text and 16 bytes more, as `Base.summarysize` counts it).

## What it reads

- TDMS 1.0 and 2.0 files (versions 4712 and 4713), little-endian
- numeric (including "with unit" floats), complex, Boolean, TimeStamp and string
  channels; a string is kept byte for byte, even where it is not valid UTF-8
  (`isvalid` tells; npTDMS replaces such bytes with U+FFFD)
- contiguous and interleaved raw data, several chunks per segment, and meta data
  that changes from segment to segment, including channels that hold no data in
  some segments; a string channel alone in a segment flagged interleaved is read
  as contiguous, as npTDMS reads it
- group and channel names holding quotes, slashes or any Unicode
- files that were never closed (the application stopped mid-write), whose last
  chunk may be partial; a file that ends inside a segment's lead-in or meta data
  gives every segment before it, with a warning

A short final chunk in a segment the writer closed is read as every channel with
fewer values, in proportion; in a segment cut short, the values stop where the
file does. NI's format description does not cover the first case; npTDMS reads
it the same way. A segment holding a string channel is the exception: strings
have no fixed size, so its short final chunk is not divided, and gives no values
in any channel (npTDMS does the same).

Refused with an error rather than misread: big-endian files, DAQmx raw data, a
string channel interleaved with other channels, string offsets that disagree
with the size their raw data index declares, interleaved channels of different
lengths, and versions other than 4712 and 4713.

## AI assistance

About two thirds of the source and most of the tests were written with Claude
Code, Anthropic's AI coding assistant (Claude Fable 5.1 and Claude Opus 5.5).
Every commit since September 2026 was made that way and carries a
`Co-Authored-By: Claude` line. On 17 October 2026, `git blame` attributes 610 of
the 910 lines in `src/` and 592 of the 706 lines in `test/` to those commits.
Dan Berge wrote the original reader in 2019, with fixes from jaakkor2, rs7q5 and
Nicolas Brantut.

Those changes were checked against npTDMS, an independent reader, on its own
test files, on truncated and corrupted copies of them, and on real LabVIEW
captures ([#12](https://github.com/DanBerge/TDMSReader.jl/pull/12),
[#13](https://github.com/DanBerge/TDMSReader.jl/pull/13)).
