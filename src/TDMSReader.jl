module TDMSReader

import BitOperations: bget
import DataStructures: OrderedDict

include("types.jl")

const _example_tdms=joinpath(@__DIR__, "..", "test", "example_files","reference_file.tdms")
const _example_incremental=[joinpath(@__DIR__, "..","test","example_files","incremental_test_$i.tdms") for i=1:6]
const _example_DAQmx=joinpath(@__DIR__,"..","test","example_files","DAQmx example.tdms")

export readtdms
export tdmsinfo, tdmsread, tdmsblocks

readtdms() = readtdms(_example_tdms)

"Bytes of channel data the file holds -- what `readtdms` would allocate."
databytes(info::TDMSInfo) = sum((ci.eltype === Nothing ? 0 : ci.nsamples * sizeof(ci.eltype)
                                 for ci in values(info.channels)); init = 0)

"""
    readtdms(fn; memory = Sys.free_memory()) -> File

Read the whole file into memory. `memory` is the byte budget the channel data
may occupy. A walk of the meta data alone (`tdmsinfo`) finds how much data the
file holds before any of it is read, so a file that would exceed the budget is
refused up front, with a pointer to `tdmsblocks` / `tdmsread`, which read on
demand. The same walk sizes every channel, so the data is allocated once rather
than grown chunk by chunk.
"""
function readtdms(fn::AbstractString; memory::Integer = Int(Sys.free_memory()))
    info = tdmsinfo(fn)
    need = databytes(info)
    need > memory && error("readtdms: $(repr(basename(fn))) holds $need bytes of channel data, more than " *
                           "memory=$memory; read it on demand with tdmsblocks or tdmsread instead")
    sizes = Dict(objectpath(g, c) => ci.nsamples for ((g, c), ci) in info.channels)
    f=File()
    objdict=ObjDict()
    open(fn) do s
        # tdmsinfo has already warned about anything odd in the file
        walksegments(s, filesize(fn), f, objdict; warn = false) do datapos, nbytes, interleaved, incomplete
            for (path, c) in objdict.current
                isempty(c.data) && sizehint!(c.data, get(sizes, path, 0))
            end
            moveto!(s, datapos)
            readrawdata!(objdict, nbytes, interleaved, incomplete, s)
        end
    end
    f
end

"""
Walk the segments of an open file: read each lead-in and its meta data into `f` and
`objdict`, and call `ondata(datapos, nbytes, interleaved, incomplete)` for each segment
that holds raw data. A segment is `incomplete` when the file was never closed (LabVIEW
crashed, power failed: the next-segment offset is all ones) or its offset runs past the
end of the file; its data then runs to the end of the file, and the walk stops after it.
A file that ends inside a lead-in, or inside the meta data of its last segment, keeps
every segment before it.
"""
function walksegments(ondata::Function, s::IO, fsize::Integer, f::File, objdict::ObjDict; warn::Bool = true)
    while !eof(s)
        startpos = position(s)
        if fsize - startpos < 28
            warn && @warn "TDMS file ends inside the lead-in of a segment at byte $startpos; the segments before it are read"
            break
        end
        (toc,nextsegmentoffset,rawdataoffset)=readleadin(s)
        room = UInt64(fsize - startpos - 28)              # bytes after this lead-in
        incomplete = nextsegmentoffset > room             # includes the never-closed all-ones offset
        segend = incomplete ? Int64(fsize) : startpos + 28 + Int64(nextsegmentoffset)
        incomplete || rawdataoffset <= nextsegmentoffset ||
            throw(ErrorException("TDMS segment at byte $startpos: raw data offset $rawdataoffset " *
                                 "lies beyond the segment ($nextsegmentoffset bytes)"))
        # raw data that would start past the end of the file is not there to read
        datapos = rawdataoffset > room ? Int64(fsize) : startpos + 28 + Int64(rawdataoffset)
        if toc.kTocNewObjList
            empty!(objdict.current)
        end
        if toc.kTocMetaData
            # meta data that may run past the end of the file is read only if it is all there
            if rawdataoffset > room && !metadatacomplete(s, objdict)
                warn && @warn "TDMS file ends inside the meta data of its last segment (byte $startpos); the segments before it are read"
                break
            end
            readmetadata!(f, objdict, s)
        end
        if toc.kTocRawData && segend > datapos
            ondata(datapos, segend - datapos, toc.kTocInterleavedData, incomplete)
        end
        incomplete && break
        moveto!(s, segend)
    end
end

"""
Whether the meta data at the stream's position reads to its end before the file does. It
is read into throwaway copies, so a segment cut off inside its meta data leaves nothing
half-read behind; the stream is put back where it was.
"""
function metadatacomplete(s::IO, objdict::ObjDict)
    p = position(s)
    trial = ObjDict()
    merge!(trial.current, objdict.current); merge!(trial.full, objdict.full)
    try
        readmetadata!(File(), trial, s)
        true
    catch e
        e isa EOFError || rethrow()
        false
    finally
        seek(s, p)
    end
end

"The path a TDMS file gives the channel `c` of group `g`; a quote in a name is written twice."
objectpath(g::AbstractString, c::AbstractString) =
    "/'" * replace(g, "'" => "''") * "'/'" * replace(c, "'" => "''") * "'"

"""
The names in a TDMS object path: none for the root `/`, the group's for `/'group'`, the
group's and the channel's for `/'group'/'channel'`. A quote inside a name is written
twice (`/'it''s'`), and a name may hold a slash.
"""
function objectnames(p::String)
    p == "/" && return String[]
    malformed() = throw(ErrorException("TDMS object path $(repr(p)) is malformed"))
    cu = codeunits(p); n = length(cu)
    names = String[]; i = 1
    while i <= n
        (i < n && cu[i] == UInt8('/') && cu[i+1] == UInt8('\'')) || malformed()
        i += 2
        buf = IOBuffer()
        while true
            i <= n || malformed()
            if cu[i] == UInt8('\'')
                i < n && cu[i+1] == UInt8('\'') || (i += 1; break)
                write(buf, UInt8('\'')); i += 2
            else
                write(buf, cu[i]); i += 1
            end
        end
        push!(names, String(take!(buf)))
    end
    1 <= length(names) <= 2 || malformed()
    names
end

"""
    tdmsinfo(fn) -> TDMSInfo

Walk the file's metadata WITHOUT reading any raw data: every property, group and
channel as `readtdms` would give them (with empty data vectors), plus per channel
the element type, the sample count the file actually holds, and where each run of
values sits on disk. `tdmsread` and `tdmsblocks` use it to read samples on demand,
so a file never has to be held in memory whole.
"""
function tdmsinfo(fn::AbstractString)
    f=File()
    objdict=ObjDict()
    runs = OrderedDict{String,Vector{Run}}()
    open(fn) do s
        walksegments(s, filesize(fn), f, objdict) do datapos, nbytes, interleaved, incomplete
            locateruns!(runs, objdict, datapos, nbytes, interleaved, incomplete)
        end
    end
    channels = OrderedDict{Tuple{String,String},ChannelInfo}()
    for (g, grp) in f.groups, (c, ch) in grp.channels
        rs = get(runs, objectpath(g, c), Run[])
        starts = cumsum([1; [r.nvalues for r in rs]])
        channels[(g, c)] = ChannelInfo(eltype(ch.data), starts[end] - 1, ch.props, rs, starts[1:end-1])
    end
    TDMSInfo(String(fn), f, channels)
end

"""
Record where the values of the current segment's channels sit, chunk after chunk,
by the same rules `readrawdata!` reads them: contiguous layout gives each channel
one run per chunk; interleaved layout gives each channel one strided run over the
whole rows the segment holds. A partial final chunk yields whole values only. A
run that continues the channel's previous one on disk (one channel written in
many chunks) extends it, so it is read in one piece.
"""
function locateruns!(runs, objdict::ObjDict, datapos::Integer, nbytes::Integer, interleaved::Bool, incomplete::Bool)
    # each channel's run list, element size and chunk length, looked up once per segment;
    # a channel the segment lists as having no raw data takes no part in it
    chans = [(get!(() -> Run[], runs, path), sizeof(eltype(c.data)), Int(c.nsamples)) for (path, c) in objdict.current if c.nsamples > 0]
    isempty(chans) && return
    if interleaved
        checkinterleaved([n for (_, _, n) in chans])
        rowbytes = sum(esz for (_, esz, _) in chans)
        rows = nbytes ÷ rowbytes
        off = 0
        for (v, esz, _) in chans
            rows > 0 && addrun!(v, Run(datapos + off, rows, rowbytes))
            off += esz
        end
    else
        nchunks, last = chunkplan([esz for (_, esz, _) in chans], [n for (_, _, n) in chans], nbytes, incomplete)
        at = Int(datapos)
        for k in 1:nchunks + 1, (i, (v, esz, nsamples)) in enumerate(chans)
            n = k <= nchunks ? nsamples : last[i]
            n > 0 && addrun!(v, Run(at, n, esz))
            at += n * esz
        end
    end
end

"""
How the raw data of a contiguous segment divides between its channels: `nchunks` whole
chunks, each holding every channel's `counts[i]` values in turn, then a short final chunk
of `last[i]` values per channel. NI's format description does not say what a short final
chunk holds. In a segment the writer closed, it is read as every channel with fewer values,
in proportion (the reading npTDMS gives such files). In an `incomplete` segment, one the
writer never finished, the values stop where the file does: channels in layout order, and
nothing after the first channel that is cut short.
"""
function chunkplan(sizes::Vector{Int}, counts::Vector{Int}, nbytes::Integer, incomplete::Bool)
    chunk = sum(Int128.(sizes) .* counts)
    nchunks, rem = Int.(divrem(Int128(nbytes), chunk))
    last = zeros(Int, length(counts))
    if !incomplete
        for i in eachindex(counts)
            last[i] = Int(div(widemul(counts[i], rem), chunk))
        end
    else
        left = rem
        for i in eachindex(counts)
            last[i] = min(counts[i], left ÷ sizes[i])
            left -= last[i] * sizes[i]
            last[i] < counts[i] && break
        end
    end
    nchunks, last
end

"Interleaved rows hold one value of every channel, so every channel must have the same length."
checkinterleaved(counts) = allequal(counts) ||
    throw(ErrorException("TDMS interleaved segment lists channels of different lengths $(counts); its rows cannot be split"))

"Append `r` to `v`, or extend the last run if `r` carries on from it on disk."
function addrun!(v::Vector{Run}, r::Run)
    if !isempty(v)
        last = v[end]
        if last.stride == r.stride && last.offset + last.nvalues * last.stride == r.offset
            v[end] = Run(last.offset, last.nvalues + r.nvalues, last.stride)
            return v
        end
    end
    push!(v, r)
end

"""
    tdmsread(fn_or_info, group, channel, range) -> Vector

Samples `range` (1-based, inclusive) of one channel, read from disk on demand. Any
part of the range outside `1:nsamples` is a `BoundsError` -- nothing is clipped
silently. Pass the `TDMSInfo` from `tdmsinfo` instead of the path to skip the
metadata walk.
"""
function tdmsread(x::Union{AbstractString,TDMSInfo}, group, channel, r::AbstractUnitRange{<:Integer})
    info = x isa TDMSInfo ? x : tdmsinfo(x)
    ci = info[group, channel]
    checkbounds(Bool, 1:ci.nsamples, r) || throw(BoundsError(1:ci.nsamples, r))
    out = Vector{ci.eltype}(undef, length(r))
    isempty(r) && return out
    open(info.path) do s
        readrange!(out, 1, s, ci, first(r), length(r))
    end
    out
end

"""
    tdmsblocks(f, fn_or_info, group, channel; blocksize = 2^20, memory = nothing) -> nsamples

Call `f(x, offset)` for consecutive blocks of one channel, `offset` being the
0-based index of the block's first sample. One buffer is reused between calls;
the last block is short, never padded. `memory` is a byte budget for that buffer
(`blocksize` is then at most `memory ÷ sizeof(eltype)`); a budget too small for a
single value is an `ArgumentError`.
"""
function tdmsblocks(f::Function, x::Union{AbstractString,TDMSInfo}, group, channel;
                    blocksize::Integer = 2^20, memory::Union{Nothing,Integer} = nothing)
    info = x isa TDMSInfo ? x : tdmsinfo(x)
    ci = info[group, channel]
    ci.nsamples == 0 && return 0
    if memory !== nothing
        cap = Int(memory) ÷ sizeof(ci.eltype)
        cap >= 1 || throw(ArgumentError("memory budget of $memory bytes holds no $(ci.eltype) value"))
        blocksize = min(blocksize, cap)
    end
    buf = Vector{ci.eltype}(undef, min(blocksize, ci.nsamples))
    open(info.path) do s
        done = 0
        while done < ci.nsamples
            n = min(blocksize, ci.nsamples - done)
            readrange!(buf, 1, s, ci, done + 1, n)
            f(view(buf, 1:n), done)
            done += n
        end
    end
    ci.nsamples
end

"""
Move `s` to byte `pos`. Forward moves use `skip`, which keeps an `IOStream`'s buffer
when `pos` is already inside it; `seek` always discards and refills it, which made
walking 20,000 small segments seven times slower.
"""
moveto!(s::IO, pos::Integer) = (d = pos - position(s)) >= 0 ? skip(s, d) : seek(s, pos)

"Fill `out[at:at+n-1]` with samples `first:first+n-1` (1-based) of the channel."
function readrange!(out::AbstractVector{T}, at::Integer, s::IO, ci::ChannelInfo, first::Integer, n::Integer) where {T}
    k = searchsortedlast(ci.starts, first)
    while n > 0 && k <= length(ci.runs)
        run = ci.runs[k]; skip = first - ci.starts[k]
        take = min(n, run.nvalues - skip)
        moveto!(s, run.offset + skip * run.stride)
        if run.stride == sizeof(T)
            read!(s, view(out, at:at + take - 1))
        else                                       # interleaved: one value per row, 2^16 rows at a time
            rows = min(take, 1 << 16)
            raw = Vector{UInt8}(undef, (rows - 1) * run.stride + sizeof(T))
            done = 0
            while done < take
                m = min(rows, take - done)
                done > 0 && moveto!(s, run.offset + (skip + done) * run.stride)
                read!(s, view(raw, 1:(m - 1) * run.stride + sizeof(T)))
                GC.@preserve raw for i in 0:m - 1
                    @inbounds out[at + done + i] = unsafe_load(Ptr{T}(pointer(raw, i * run.stride + 1)))
                end
                done += m
            end
        end
        fixlayout!(view(out, at:at + take - 1))
        first += take; at += take; n -= take; k += 1
    end
    out
end

function readleadin(s::IO)
    at = position(s)
    tag = read(s, 4)
    tag == b"TDSm" || throw(ErrorException("Not a TDMS segment at byte $at: it starts $(repr(String(copy(tag)))), not \"TDSm\""))
    toc=ToC(ltoh(read(s, UInt32)))
    toc.kTocBigEndian && throw(ErrorException("Big Endian files not supported"))
    # 4712 is TDMS 1.0 (what npTDMS writes), 4713 TDMS 2.0; the layout read here is common to both
    version = read(s, UInt32)
    version in (4712, 4713) || throw(ErrorException("TDMS segment at byte $at has version $version; only 4712 and 4713 are known"))

    return (toc=toc,nextsegmentoffset=read(s, UInt64),rawdataoffset=read(s, UInt64),)
end

function readmetadata!(f::File, objdict::ObjDict, s::IO)
    n = read(s, UInt32)
    for i=1:n
        readobj!(f, objdict, s)
    end
end

function readobj!(f::File, objdict::ObjDict, s::IO)
    objpath = readstring(s)
    # @info "Read @ position $(hexstring(position(s)))"
    rawdata=read(s, UInt32)
    hasrawdata=false
    hasnewchunk=false
    if rawdata==0xFF_FF_FF_FF #No Raw Data
        # in this segment: a channel carried over from the last one keeps its place in
        # the object list, but holds no values here
        if haskey(objdict.current, objpath)
            c = objdict.current[objpath]
            objdict.current[objpath] = Chunk{eltype(c.data)}(c.data, zero(UInt64))
        end
    elseif rawdata==zero(UInt32) #Keep Chunk layout
        haskey(objdict.full, objpath) || throw(ErrorException("Previous Segment Missing"))
        hasrawdata=true
        T=eltype(objdict.full[objpath].data)
    elseif rawdata==0x00_00_12_69 || rawdata==0x00_00_13_69
        readDAQmx(s::IO, rawdata)
        throw(ErrorException("Not Implemented"))
    else
        hasrawdata=true
        hasnewchunk=true
        T=tdstype(read(s, UInt32))
        ( T <: TDMSUnimplementedType ) && throw(ErrorException("TDMS Data Type of $T is not supported"))
        read(s,UInt32)==1 || throw(ErrorException("TDMS Array Dimension is not 1"))
        n=read(s,UInt64)
        # 2^56 values of 16 bytes or less: more than any file holds, and safe to multiply
        n <= 1 << 56 || throw(ErrorException("TDMS channel $objpath declares $n values per chunk; the file is damaged"))
        if T == String
            throw(ErrorException("Need Functionality to Read String as raw data"))
        end
    end

    if objpath=="/"
        hasrawdata && throw(ErrorException("TDMS root should not have raw data"))
        props=f.props
        readprop!(props,s)
    else
        names = objectnames(objpath)
        group = names[1]
        channel = length(names) == 2 ? names[2] : nothing
        g=if haskey(f.groups, group)
            f[group]
        else
            get!(f.groups,group,Group())
        end
        if isnothing(channel) # Is a Group
            hasrawdata && throw(ErrorException("TDMS Group should not have raw data"))
            readprop!(g.props,s)
        else # Is  a Channel
            if haskey(g.channels,channel)
                if hasnewchunk && eltype(g[channel].data)==Nothing #need to replace existing channel if created without having data
                    setindex!(g.channels,TDMSReader.Channel{T}(g[channel].props),channel) #convert existing channel
                elseif hasnewchunk && eltype(g[channel].data) != T
                    throw(ErrorException("TDMS channel $objpath changes data type from $(eltype(g[channel].data)) to $T"))
                end
                chan = g[channel]
            else
                chan=if hasrawdata
                    get!(g.channels, channel, TDMSReader.Channel{T}())
                else
                    get!(g.channels, channel, TDMSReader.Channel{Nothing}())
                end
            end
            readprop!(chan.props, s)
        end
    end

    if hasrawdata
        if hasnewchunk
            objdict.full[objpath]=Chunk{T}(chan.data,n)
        end
        objdict.current[objpath]=objdict.full[objpath]
    end
end

# Strings are read with `read(s, n)`, which allocates n bytes: `readbytes!` into an
# empty vector first grows it to 64 KiB, which cost that much per string in the meta data.
"""
A length-prefixed string; a file that ends inside it is an `EOFError`, not a short
string. A length longer than the rest of the file (a damaged length field) is refused
before anything is allocated; only long strings pay for the check.
"""
function readstring(s::IO)
    n = read(s, UInt32)
    n > 1 << 16 && s isa IOStream && n > filesize(s) - position(s) && throw(EOFError())
    b = read(s, n)
    length(b) == n || throw(EOFError())
    String(b)
end

function readprop!(props, s::IO)
    n=read(s,UInt32)
    for i=1:n
        propname = readstring(s)
        T = tdstype(read(s,UInt32))
        if T==String
            props[propname] = readstring(s)
        else
            propval=read(s,T)
            props[propname]=propval
        end
    end
end

function readrawdata!(objects::NTuple{N,Chunk}, nbytes::Integer, s::IO) where N
    n = 0
    while n < nbytes && !eof(s)
        for x in objects
            T = eltype(x.data)
            for i=1:x.nsamples
                push!(x.data, read(s,T))
                n += sizeof(T)
            end
        end
    end
    return nothing
end

"""
Read `nbytes` of raw data for the channels in `objdict.current`, chunk after chunk.
Contiguous layout: each chunk holds every channel's `nsamples` values one channel
after another. Interleaved layout (`kTocInterleavedData`): each chunk holds
`nsamples` rows of one value per channel. A final chunk that the file cuts short
yields as many whole values as it holds, in layout order, and no more.
"""
function readrawdata!(objdict::ObjDict, nbytes::Integer, interleaved::Bool, incomplete::Bool, s::IO)
    # a channel the segment lists as having no raw data takes no part in it
    chans = [c for c in values(objdict.current) if c.nsamples > 0]
    isempty(chans) && return nothing
    left = Int(nbytes)
    if interleaved
        # Whole rows only, read in blocks of at most 16 MiB and split per channel.
        checkinterleaved([Int(c.nsamples) for c in chans])
        rowbytes = sum(sizeof(eltype(c.data)) for c in chans)
        rows = left ÷ rowbytes
        buf = Vector{UInt8}(undef, min(rows, max(1, (1 << 24) ÷ rowbytes)) * rowbytes)
        done = 0
        while done < rows
            k = min(rows - done, length(buf) ÷ rowbytes)
            read!(s, view(buf, 1:k*rowbytes))
            off = 0
            for c in chans
                deinterleave!(c.data, buf, off, rowbytes, k)
                off += sizeof(eltype(c.data))
            end
            done += k
        end
    else
        counts = [Int(c.nsamples) for c in chans]
        nchunks, last = chunkplan([sizeof(eltype(c.data)) for c in chans], counts, left, incomplete)
        for _ in 1:nchunks, (c, n) in zip(chans, counts)
            readchunk!(c.data, n, s)
        end
        for (c, n) in zip(chans, last)
            readchunk!(c.data, n, s)
        end
    end
    return nothing
end

"Append `k` values of `T` to `v`, `stride` bytes apart in `buf` from byte offset `off`."
function deinterleave!(v::Vector{T}, buf::Vector{UInt8}, off::Int, stride::Int, k::Int) where {T}
    m = length(v)
    resize!(v, m + k)
    GC.@preserve buf for i in 0:k-1
        @inbounds v[m + 1 + i] = unsafe_load(Ptr{T}(pointer(buf, off + i * stride + 1)))
    end
    fixlayout!(view(v, m+1:m+k))
    v
end

"Append `n` values of `T` to `v` in one read; returns the bytes consumed."
function readchunk!(v::Vector{T}, n::Integer, s::IO) where {T}
    n <= 0 && return 0
    m = length(v)
    resize!(v, m + n)
    read!(s, view(v, m+1:m+n))
    fixlayout!(view(v, m+1:m+n))
    n*sizeof(T)
end

function seekalign(s::IO)
    x = position(s)
    mask = typeof(x)(0b11)
    seek(s, ifelse(x & mask > 0,x  & ~mask + 4, x))
end

function readDAQmx(s::IO, id)
    @debug "Read DAQmc Raw Data @ $(hexstring(id))"
    T = tdstype(read(s, UInt32))
    @debug "Data type $T"
    read(s, UInt32)==1 || throw(ErrorException("TDMS Array Dimension is not 1"))
    chunksize = read(s, UInt64)
    @debug "Chunk size = $chunksize"

    @debug "Read vector of format change scalers"
    vectorsize = read(s, UInt32)
    V = tdstype(read(s, UInt32))
    rawbufferindex = read(s, UInt32)
    rawbyteoffset = read(s, UInt32)
    sampleformatbitmap = read(s, UInt32)
    scaleid = read(s,UInt32)
    @debug "Vector Size = $vectorsize"
    @debug "DAQmx data type = $V"
    @debug "Raw Buffer Index = $rawbufferindex"
    @debug "Raw byte offset = $rawbyteoffset"
    @debug "Sample Format Bitmatp = $sampleformatbitmap"
    @debug "Scale ID = $scaleid"
    # Parsing stops here: the caller raises "Not Implemented". (An empty loop over an
    # undefined `n` used to raise UndefVarError first, hiding that message.)
end

function hexstring(x::Integer)
    "0x$(lpad(string(x,base=16),8,'0'))"
end

end # module
