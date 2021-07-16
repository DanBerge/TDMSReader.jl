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
    while !eof(s)
        (toc,nextsegmentoffset,rawdataoffset)=readleadin(s)
        if toc.kTocNewObjList
            empty!(objdict.current)
        end
        if toc.kTocMetaData
            readmetadata!(f, objdict, s)
        end
        if toc.kTocRawData
            readrawdata!(objdict, nextsegmentoffset-rawdataoffset, s)
        end
    end
    close(s)
    f
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
    b=UInt8[]
    readbytes!(s, b, read(s, UInt32))
    objpath = String(b); empty!(b)
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
            chan=if haskey(g.channels,channel)
                g[channel]
            else
                if hasrawdata
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

function readprop!(props, s::IO)
    b=UInt8[]
    n=read(s,UInt32)
    for i=1:n
        readbytes!(s, b, read(s, UInt32))
        propname = String(b); empty!(b)
        T = tdsTypes[read(s,UInt32)]
        if T==String
            readbytes!(s, b, read(s, UInt32))
            props[propname] = String(b)
            empty!(b)
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

function readrawdata!(objdict::ObjDict, nbytes::Integer, s::IO)
    n = 0
    while n < nbytes && !eof(s)
        for (key,val) in objdict.current
            n += readchunk!(val.data, val.nsamples, s)
        end
    end
    return nothing
end

function readchunk!(v::Vector{T}, n::Integer, s::IO) where {T}
    for i = 1:n
        push!(v, read(s,T))
    end
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

    for i in 1:n

    end

end

function hexstring(x::Integer)
    "0x$(lpad(string(x,base=16),8,'0'))"
end

end # module
