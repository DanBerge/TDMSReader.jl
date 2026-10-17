module TDMSReader

import BitOperations: bget
import DataStructures: OrderedDict

include("types.jl")

const _example_tdms=(@__DIR__) * "\\..\\test\\example_files\\reference_file.tdms"
const _example_incremental=[(@__DIR__) * "\\..\\test\\example_files\\incremental_test_$i.tdms" for i=1:6]
const _example_DAQmx=(@__DIR__) * "\\..\\test\\example_files\\DAQmx example.tdms"

export readtdms

readtdms() = readtdms(_example_tdms)
function readtdms(fn::AbstractString)
    s = open(fn)
    f=File()
    objdict=ObjDict()
    fsize = filesize(fn)
    while !eof(s)
        startpos = position(s)
        (toc,nextsegmentoffset,rawdataoffset)=readleadin(s)
        if toc.kTocNewObjList
            empty!(objdict.current)
        end
        if toc.kTocMetaData
            readmetadata!(f, objdict, s)
        end
        # A file that was never closed (LabVIEW crashed, power failed) carries an
        # all-ones next-segment offset: its data runs to end of file, and the last
        # chunk may be partial. Clamp to what the file actually holds.
        datapos = startpos + 28 + Int64(rawdataoffset)
        segend = nextsegmentoffset == typemax(UInt64) ? fsize : min(fsize, startpos + 28 + Int64(nextsegmentoffset))
        if toc.kTocRawData
            seek(s, datapos)
            readrawdata!(objdict, segend - datapos, toc.kTocInterleavedData, s)
        end
        nextsegmentoffset == typemax(UInt64) && break
        seek(s, segend)
    end
    close(s)
    f
end

function readseginfo(fn::AbstractString)
    #STILL COULD USE SOME WORK HERE TO MAKE IT CLEAN AND NEAT
    s = open(fn)
    f=File()
    objdict=ObjDict()
    tdmsSeg = OrderedDict()
    lead_size = 28 #lead in is 28 bytes
    segCnt = 0
    while !eof(s)
        startPos = position(s)
        (toc,nextsegmentoffset,rawdataoffset)=readleadin(s)
        if toc.kTocNewObjList
            empty!(objdict.current)
        end

        nobj = read(s, UInt32)
        seek(s,startPos+lead_size)
        if toc.kTocMetaData
            readmetadata!(f, objdict, s)
        end
        if toc.kTocRawData
            #readrawdata!(objdict, nextsegmentoffset-rawdataoffset, s)
        end
        nextsegmentPos = Int64(startPos+nextsegmentoffset+lead_size)
        dataPos = Int64(startPos+lead_size+rawdataoffset)
        rawdatasize = nextsegmentoffset-rawdataoffset
        tdmsTmp = SegInfo(startPos,toc,nextsegmentPos,dataPos,nobj,rawdatasize)
        segCnt +=1
        tdmsSeg[string("seg",segCnt)] = tdmsTmp
        seek(s,nextsegmentPos)
    end
    close(s)
    return f,objdict,tdmsSeg
end

function readleadin(s::IO)
    @assert ntoh(read(s, UInt32)) == 0x54_44_53_6D
    toc=ToC(ltoh(read(s, UInt32)))
    toc.kTocBigEndian && throw(ErrorException("Big Endian files not supported"))
    read(s, UInt32) == 4713 || throw(ErrorException("File not recongnized as TDMS formatted file"))

    return (toc=toc,nextsegmentoffset=read(s, UInt64),rawdataoffset=read(s, UInt64),)
end

function readmetadata!(f::File, objdict::ObjDict, s::IO)
    n = read(s, UInt32)
    for i=1:n
        readobj!(f, objdict, s)
    end
end

function readobj!(f::File, objdict::ObjDict, s::IO)
    objpath = String(read(s, read(s, UInt32)))
    # @info "Read @ position $(hexstring(position(s)))"
    rawdata=read(s, UInt32)
    hasrawdata=false
    hasnewchunk=false
    if rawdata==0xFF_FF_FF_FF #No Raw Data
    elseif rawdata==zero(UInt32) #Keep Chunk layout
        haskey(objdict.full, objpath) || throw(ErrorException("Previous Segment Missing"))
        hasrawdata=true
    elseif rawdata==0x00_00_12_69 || rawdata==0x00_00_13_69
        readDAQmx(s::IO, rawdata)
        throw(ErrorException("Not Implemented"))
    else
        hasrawdata=true
        hasnewchunk=true
        T=tdsTypes[read(s, UInt32)]
        ( T <: TDMSUnimplementedType ) && throw(ErrorException("TDMS Data Type of $T is not supported"))
        read(s,UInt32)==1 || throw(ErrorException("TDMS Array Dimension is not 1"))
        n=read(s,UInt64)
        if T == String
            throw(ErrorException("Need Functionality to Read String as raw data"))
        end
    end

    if objpath=="/"
        hasrawdata && throw(ErrorException("TDMS root should not have raw data"))
        props=f.props
        readprop!(props,s)
    else
        m=match(r"\/'(.+?)'(?:\/'(.+)')?", objpath)
        isnothing(m.captures) && throw(ErrorException("Object Path $objpath is malformed"))
        group,channel=m.captures[1:2]
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
function readprop!(props, s::IO)
    n=read(s,UInt32)
    for i=1:n
        propname = String(read(s, read(s, UInt32)))
        T = tdsTypes[read(s,UInt32)]
        if T==String
            props[propname] = String(read(s, read(s, UInt32)))
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
function readrawdata!(objdict::ObjDict, nbytes::Integer, interleaved::Bool, s::IO)
    chans = collect(values(objdict.current))
    isempty(chans) && return nothing
    left = Int(nbytes)
    if interleaved
        # Whole rows only, read in blocks of at most 16 MiB and split per channel.
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
        while left > 0
            before = left
            for c in chans
                left -= readchunk!(c.data, min(Int(c.nsamples), left ÷ sizeof(eltype(c.data))), s)
                left > 0 || break
            end
            left < before || break        # only a fragment of a value remains
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
    @info "Read DAQmc Raw Data @ $(hexstring(id))"
    T = tdsTypes[read(s, UInt32)]
    @info "Data type $T"
    read(s, UInt32)==1 || throw(ErrorException("TDMS Array Dimension is not 1"))
    chunksize = read(s, UInt64)
    @info "Chunk size = $chunksize"

    @info "Read vector of format change scalers"
    vectorsize = read(s, UInt32)
    V = tdsTypes[read(s, UInt32)]
    rawbufferindex = read(s, UInt32)
    rawbyteoffset = read(s, UInt32)
    sampleformatbitmap = read(s, UInt32)
    scaleid = read(s,UInt32)
    @info "Vector Size = $vectorsize"
    @info "DAQmx data type = $V"
    @info "Raw Buffer Index = $rawbufferindex"
    @info "Raw byte offset = $rawbyteoffset"
    @info "Sample Format Bitmatp = $sampleformatbitmap"
    @info "Scale ID = $scaleid"
    # Parsing stops here: the caller raises "Not Implemented". (An empty loop over an
    # undefined `n` used to raise UndefVarError first, hiding that message.)
end

function hexstring(x::Integer)
    "0x$(lpad(string(x,base=16),8,'0'))"
end

end # module
