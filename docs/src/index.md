# TDMSReader.jl

Read National Instruments TDMS files in native Julia.

## Installing

```julia
using Pkg
Pkg.add(url = "https://github.com/DanBerge/TDMSReader.jl")
```

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

## Reading on demand

```julia
info = tdmsinfo("measurement.tdms")   # the meta data only; no samples are read
x = tdmsread(info, "Group", "Channel1", 1_000_001:2_000_000)
tdmsblocks(info, "Group", "Channel1"; blocksize = 2^20) do x, offset
    # x: the next block of samples; offset: 0-based index of x[1]
end
```

Every function is described in the [Reference](@ref). What the reader covers and
how it is checked is in the
[README](https://github.com/DanBerge/TDMSReader.jl#readme).
