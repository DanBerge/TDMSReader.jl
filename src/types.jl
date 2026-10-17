import Dates: Nanosecond, Second
import TimesDates: TimeDate
import Base: ==

abstract type TDMSUnimplementedType end
struct tdsTypeVoid <: TDMSUnimplementedType end
struct tdsTypeExtendedFloat <: TDMSUnimplementedType end
struct tdsTypeSingleFloatWithUnit <: TDMSUnimplementedType end
struct tdsTypeDoubleFloatWithUnit <: TDMSUnimplementedType end
struct tdsTypeExtendedFloatWithUnit <: TDMSUnimplementedType end
struct tdsTypeDAQmxRawData <: TDMSUnimplementedType end

abstract type TDMSType end
struct TimeStamp <: TDMSType
    seconds::Int64
    fractions::UInt64
end
const epoch=TimeDate(1904,1,1)
function TimeDate(x::TimeStamp)
    ns = round(x.fractions*(2.0^-64)*1e9)
    epoch + Second(x.seconds) + Nanosecond(ns)
end
function Base.:+(x::T,y::T) where {T<:TimeStamp}
    s = x.seconds + y.seconds
    r,f = Base.Checked.add_with_overflow(x.fractions, y.fractions)
    f ? TimeStamp(s+1,r) : TimeStamp(s,r)
end
function Base.:-(x::T,y::T) where {T<:TimeStamp}
    s = x.seconds - y.seconds
    r,f = Base.Checked.sub_with_overflow(x.fractions, y.fractions)
    f ? TimeStamp(s-1,r) : TimeStamp(s,r)
end
Base.show(io::IO,ts::TimeStamp) = show(io,TimeDate(ts))
Base.show(ts::TimeStamp) = show(TimeDate(ts))


function Base.:read(s::IO, ::Type{TimeStamp})
    fractions=read(s,UInt64)
    seconds=read(s, Int64)
    TimeStamp(seconds,fractions)
end

"""
Put values copied byte for byte from the file into the element type's field order.
Only TimeStamp differs: the file holds (fractions, seconds), the struct (seconds,
fractions). Every other element type is already in order.
"""
fixlayout!(v::AbstractVector) = v
function fixlayout!(v::AbstractVector{TimeStamp})
    for i in eachindex(v)
        x = v[i]
        v[i] = TimeStamp(reinterpret(Int64, x.fractions), reinterpret(UInt64, x.seconds))
    end
    v
end

const tdsTypes=Dict{UInt32,DataType}(0=>tdsTypeVoid, 1=>Int8, 2=>Int16, 3=>Int32, 4=>Int64,
    5=>UInt8, 6=>UInt16, 7=>UInt32, 8=>UInt64, 9=>Float32, 10=>Float64, 11=>tdsTypeExtendedFloat,
    0x19=>tdsTypeSingleFloatWithUnit, 0x1A => tdsTypeDoubleFloatWithUnit, 0x1B => tdsTypeExtendedFloatWithUnit,
    0x20=>String, 0x21=>Bool, 0x08000C=>ComplexF32, 0x10000D=>ComplexF64, 0xFF_FF_FF_FF=>tdsTypeDAQmxRawData,
    0x44=>TimeStamp )

struct ToC
    kTocMetaData::Bool
    kTocRawData::Bool
    kTocDAQmxRawData::Bool
    kTocInterleavedData::Bool
    kTocBigEndian::Bool
    kTocNewObjList::Bool
end

function ToC(a::UInt32)
    ToC(
        bget(a,1),
        bget(a,3),
        bget(a,7),
        bget(a,5),
        bget(a,6),
        bget(a,2)
    )
end

struct Channel{T}
    data::Vector{T}
    props::OrderedDict{String,Any}

    Channel{T}() where {T} = new(Vector{T}(),OrderedDict{String,Any}())
    Channel{T}(props) where {T} = new(Vector{T}(),props) #already have props 
end
==(a::TDMSReader.Channel,b::TDMSReader.Channel) = (a.props == b.props) && (a.data == b.data)

struct Group
    channels::OrderedDict{String,TDMSReader.Channel}
    props::OrderedDict{String,Any}

    Group()= new(OrderedDict{String,Channel}(),OrderedDict{String,Any}())
end
Base.:haskey(h::Group, key)=haskey(h.channels, key)
Base.:getkey(h::Group, key)=haskey(h.channels, key)
Base.:keys(a::Group)=keys(a.channels)
==(a::Group,b::Group) = (a.props == b.props) && (a.channels == b.channels)

struct File
    groups::OrderedDict{String,Group}
    props::OrderedDict{String,Any}

    File() = new(OrderedDict{String,Group}(),OrderedDict{String,Any}())
end
Base.:haskey(h::File, key)=haskey(h.groups, key)
Base.:getkey(h::File, key)=haskey(h.groups, key)
Base.:keys(a::File)=keys(a.groups)
==(a::File,b::File) = (a.props == b.props) && (a.groups == b.groups)

struct Chunk{T}
    data::Vector{T}
    nsamples::UInt64
end

struct ObjDict
    current::OrderedDict{String,Chunk}
    full::OrderedDict{String,Chunk}

    ObjDict() = new(OrderedDict{String,Chunk}(),OrderedDict{String,Chunk}())
end

function Base.:getindex(f::File, group::Union{Integer,AbstractString}, channel::Nothing=nothing)
    if group isa Integer
        k=collect(keys(f.groups))[group]
        f.groups[k]
    else
        f.groups[group]
    end
end


function Base.:getindex(f::File, group::Union{Integer,AbstractString}, channel::Union{Integer,AbstractString})
    if group isa Integer
        k=collect(keys(f.groups))[group]
        f.groups[k][channel]
    else
        f.groups[group][channel]
    end
end

function Base.:getindex(g::Group, channel::Union{Integer,AbstractString})
    if channel isa Integer
        k=collect(keys(g.channels))[channel]
        g.channels[k]
    else
        g.channels[channel]
    end
end

"""
One run of a channel's raw values on disk: `nvalues` values starting at byte
`offset`, `stride` bytes apart (the element size when the chunk is contiguous,
the row size when it is interleaved).
"""
struct Run
    offset::Int64
    nvalues::Int64
    stride::Int64
end

"What `tdmsinfo` knows about one channel without reading its data."
struct ChannelInfo
    eltype::DataType
    nsamples::Int64
    props::OrderedDict{String,Any}
    runs::Vector{Run}
    starts::Vector{Int64}        # 1-based sample index at which each run begins
end

"""
`tdmsinfo(path)`: the `File` (properties, groups, channels -- with EMPTY data
vectors) plus, per `(group, channel)`, a `ChannelInfo` giving the element type,
the sample count the file actually holds, and where its values live. Index it
like a `File`: `info["Group", "Channel1"]` or `info[1, 1]`.
"""
struct TDMSInfo
    path::String
    file::File
    channels::OrderedDict{Tuple{String,String},ChannelInfo}
end
Base.keys(i::TDMSInfo) = keys(i.channels)
Base.getindex(i::TDMSInfo, group::AbstractString, channel::AbstractString) = i.channels[(String(group), String(channel))]
function Base.getindex(i::TDMSInfo, group::Integer, channel::Integer)
    g = collect(keys(i.file.groups))[group]
    c = collect(keys(i.file.groups[g].channels))[channel]
    i.channels[(g, c)]
end
Base.getindex(i::TDMSInfo, group::AbstractString, channel::Integer) =
    i.channels[(String(group), collect(keys(i.file.groups[group].channels))[channel])]
Base.getindex(i::TDMSInfo, group::Integer, channel::AbstractString) =
    i.channels[(collect(keys(i.file.groups))[group], String(channel))]
