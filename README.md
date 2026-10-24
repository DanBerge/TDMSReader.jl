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

`tdmsread(Float64, info, "Group", "Channel1", r)` names the element type, so the
result is inferred as `Vector{Float64}` (an `ArgumentError` for a channel of another
type); without it, code that loops over the samples is fastest behind a function
barrier.

## Reading from a stream

`readtdms`, `tdmsinfo`, `tdmsread` and `tdmsblocks` also take a seekable stream (an
`IOStream` or `IOBuffer`) in place of the path, and read the file from the stream's
position to its end: `readtdms(IOBuffer(bytes))`. The info of a stream reads its
samples from that stream, which must stay open.

## Time

A `TimeStamp` converts with `DateTime(t)` (milliseconds) or `TimeDate(t)`
(nanoseconds), and orders with `<`, `sort` and `maximum`. `TDMSReader.timeaxis(ch)`
is the time of each sample of a waveform channel in seconds, from its
`wf_start_offset` and `wf_increment`.

## With other packages

These load only beside the package they name (Julia 1.9 package extensions):

- **Tables.jl**: a group whose channels are the same length is a table, so
  `DataFrame(f["Group"])` works.
- **Unitful**: `TDMSReader.withunits(ch)` gives the samples in the unit its
  `unit_string` names, or `withunits(ch, u"V")` for a unit Unitful does not read.
- **FileIO**: `load("measurement.tdms")` calls `readtdms`, once TDMS is in FileIO's
  registry.

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

## How it is checked

- **An independent reader.** 108 files: every file npTDMS's own test suite writes,
  its four example files, and 18 more for cases in this code. npTDMS and this
  package read each one, and must agree on every value and property. They agree on
  68. The rest are files this package refuses (DAQmx, big-endian, a version it does
  not know), files npTDMS refuses, and four where npTDMS widens a Float32 property
  to Float64.
- **Cut-off files.** Every prefix of the files both read (19,748 files: a crash at
  each byte) reads as npTDMS reads it, except 8 where this package keeps a
  segment's complete meta data that npTDMS drops.
- **Damaged files.** 13,400 random corruptions of those files are read or refused
  with an error: none ends in an internal error, allocates more than 512 MiB or
  takes more than 5 s.
- **Real captures.** 97 LabVIEW captures, 1 KB to 8.6 GB, read identically by
  npTDMS and this package.
- **CI** runs the tests on Julia 1.10 (the oldest supported) and the current release,
  on Linux, Windows and macOS, and once more with every dependency at the oldest
  version its compat entry allows.

The comparisons run outside the test suite; each problem they found has a test of
its own.

## AI disclosure

Since September 2026 this package has been written with Claude Code (Claude Fable
5.1, then Claude Opus 5.5) assisting: about two thirds of the source and most of
the tests (by `git blame` on 17 October 2026, 612 of the 890 lines in `src/` and
782 of the 896 in `test/`). Dan Berge wrote the original reader in 2019, with
fixes from jaakkor2, rs7q5 and Nicolas Brantut. The real captures it is checked on
are mine. I reviewed every change by hand, and the commits Claude contributed to
carry a `Co-Authored-By: Claude` trailer. See [AI_DISCLOSURE.md](AI_DISCLOSURE.md).
