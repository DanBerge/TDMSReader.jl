# TDMSReader
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
takes `memory`, a byte budget for its buffer, as well as `blocksize`.
`TDMSReader.databytes(info)` is the number of bytes `readtdms` would allocate.

## What it reads

- TDMS 2.0 files (version 4713), little-endian
- numeric and TimeStamp channels
- contiguous and interleaved raw data, several chunks per segment, and meta data
  that changes from segment to segment
- files that were never closed (the application stopped mid-write), whose last
  chunk may be partial

Refused with an error rather than misread: big-endian files, DAQmx raw data,
string channels, and TDMS 1.0 files (version 4712).
