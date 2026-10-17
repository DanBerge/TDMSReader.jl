using TDMSReader
using Test

let a=TDMSReader.readtdms( TDMSReader._example_tdms )
    g=a.groups["Group"]
    c=g.channels["Channel1"]
    @testset "Basic Example File" begin
        @test isempty(a.props)
        @test g.props == Dict("prop" => "value", "num" => 10)
        @test isempty(c.props)
        @test isempty(c.data)
    end

    @testset "Indexing and Keys" begin
        @test Set(["Group"]) == keys(a)
        @test a.groups["Group"] == a["Group"] == a[1]
        @test keys(g.channels) == Set(["Channel1"])
        @test a["Group"] == a[1]
        @test a["Group"]["Channel1"]==a["Group","Channel1"]
        @test a["Group"][1]==a["Group",1]
        @test a[1]["Channel1"]==a[1,"Channel1"]
        @test a[1][1]==a[1,1]
        @test_throws BoundsError a[2]
        @test_throws BoundsError a[1,2]
        @test_throws KeyError a["BadKey"]
        @test_throws KeyError a[1,"BadKey"]
    end

    @testset "Equality Test" begin
        b=deepcopy(a)
        @test a[1,1]==b[1,1]
        @test a[1]==b[1]
        @test a==b

        a.props["NewVal"]="Val"
        b.props["NewVal"]="Val"
        @test a==a
        b.props["NewVal"]="Changed"
        @test a != b

        a[1].props["NewVal"]="Val"
        b[1].props["NewVal"]="Val"
        @test a[1]==a[1]
        b[1].props["NewVal"]="Changed"
        @test a[1] != b[1]

        a[1,1].props["NewVal"]="Val"
        b[1,1].props["NewVal"]="Val"
        @test a[1,1] == b[1,1]
        let b=deepcopy(b)
            b[1,1].props["NewVal"]="Changed"
            @test a[1,1] != b[1,1]
        end
        push!(a[1,1].data,4)
        @test a[1,1] != b[1,1]
        push!(b[1,1].data,4)
        @test a[1,1] == b[1,1]

        b.props["NewVal"]="Val"
        b[1].props["NewVal"]="Val"
        b[1,1].props["NewVal"]="Val"
        @test a[1,1]==b[1,1]
        @test a[1]==b[1]
        @test a==b
    end
end

let fn=TDMSReader._example_incremental
    a=TDMSReader.readtdms(first(fn))
    @testset "Incremental Files" begin
        @test a[1,1].data==[1:3;] && a[1,2].data==[4:6;]

        b=TDMSReader.readtdms(fn[2])
        @test a != b
        append!(a[1,1].data, [1:3;])
        append!(a[1,2].data, [4:6;])
        @test a==b

        b=TDMSReader.readtdms(fn[3])
        @test a != b
        append!(a[1,1].data,[1:3;])
        append!(a[1,2].data, [4:6;])
        @test a[1,1].data == b[1,1].data && a[1,2].data == b[1,2].data
        @test a[1,1].props["prop"] == "valid" && b[1,1].props["prop"] == "error"
        @test a[1,1] != a[1,2]
        a[1,1].props["prop"]="error"
        @test a == b

        #Add new voltage channel
        b=TDMSReader.readtdms(fn[4])
        @test collect(keys(b[1]))==["channel1","channel2","voltage"]
        append!(a[1,1].data,[1:3;])
        append!(a[1,2].data,[4:6;])
        a[1].channels["voltage"]=TDMSReader.Channel{Int}()
        append!(a[1,"voltage"].data, [7:11;])
        @test a == b

        b=TDMSReader.readtdms(fn[5])
        append!(a[1,1].data,[1:3;])
        append!(a[1,2].data,[1:27;])
        append!(a[1,3].data,[7:11;])
        @test a[1,1] == b[1,1]
        @test a[1,2] == b[1,2]
        @test a[1,3] == b[1,3]
        @test a == b

        # Stop appending channel #2
        b=TDMSReader.readtdms(fn[6])
        append!(a[1,1].data,[1:3;])
        append!(a[1,3].data,[7:11;])
        @test a == b

    end
end

let dir=joinpath(@__DIR__, "example_files")
    # Two channels written sample-interleaved (kTocInterleavedData set): rows of
    # (ch1, ch2) = (1,-1), (2,-2), ... Reading them as two contiguous blocks
    # gives each channel half of the other's samples.
    @testset "Interleaved Channels" begin
        a=TDMSReader.readtdms(joinpath(dir, "interleaved.tdms"))
        @test a[1,"ch1"].data == Int16[1:8;]
        @test a[1,"ch2"].data == -Int16[1:8;]
    end

    # A file LabVIEW never closed: the last segment's next-segment offset is all
    # ones, its data runs to end of file, and the final chunk is partial (7 of the
    # declared 12 values, then a stray byte that is not a whole Int16).
    @testset "Never-Closed File" begin
        a=TDMSReader.readtdms(joinpath(dir, "never_closed.tdms"))
        @test a[1,"ch1"].data == Int16[1:19;]
    end

    # DAQmx raw data is not implemented; say so, rather than fail on an undefined variable
    @testset "DAQmx Refused" begin
        @test_throws ErrorException TDMSReader.readtdms(TDMSReader._example_DAQmx)
    end
end

# A minimal TDMS 2.0 writer, after NI's "TDMS File Format Internal Structure": the
# 28-byte lead-in, meta data (object paths, raw data indexes, string properties),
# then the raw data. Objects are (path, T, nvalues, props); T === nothing: no raw data.
tdms_str(s) = vcat(collect(reinterpret(UInt8, [UInt32(ncodeunits(s))])), codeunits(s))
tdms_code(T) = T === Int16 ? UInt32(0x02) : T === TDMSReader.TimeStamp ? UInt32(0x44) : error("no TDMS code for $T here")
function tdms_segment(io, objs, raw::AbstractVector{UInt8}; interleaved = false)
    meta = IOBuffer()
    write(meta, UInt32(length(objs)))
    for (path, T, n, props) in objs
        write(meta, tdms_str(path))
        T === nothing ? write(meta, 0xFFFFFFFF) : write(meta, UInt32(20), tdms_code(T), UInt32(1), UInt64(n))
        write(meta, UInt32(length(props)))
        for (k, v) in props
            write(meta, tdms_str(k), UInt32(0x20), tdms_str(v))
        end
    end
    m = take!(meta)
    toc = UInt32(1 << 1 | 1 << 2) | (isempty(raw) ? UInt32(0) : UInt32(1 << 3)) | (interleaved ? UInt32(1 << 5) : UInt32(0))
    write(io, b"TDSm", toc, UInt32(4713), UInt64(length(m) + length(raw)), UInt64(length(m)), m, raw)
end

# Reading should cost about the data it returns: not a boxed value per sample
# (interleaved rows), and not a 64 KiB buffer per string in the meta data.
@testset "Reading costs about the data" begin
    dir = mktempdir()
    n = 200_000
    chans = [Int16.(mod.(k .* (1:n), 2001) .- 1000) for k in 1:4]
    p = joinpath(dir, "interleaved_large.tdms")
    open(p, "w") do io
        objs = [("/", nothing, 0, []), ("/'G'", nothing, 0, []), [("/'G'/'c$k'", Int16, n, []) for k in 1:4]...]
        tdms_segment(io, objs, reinterpret(UInt8, vec(permutedims(hcat(chans...)))); interleaved = true)
    end
    a = TDMSReader.readtdms(p)
    @test all(a["G", "c$k"].data == chans[k] for k in 1:4)
    @test @allocated(TDMSReader.readtdms(p)) < 4 * (4n * sizeof(Int16))

    q = joinpath(dir, "segments.tdms")
    open(q, "w") do io
        for s in 1:300
            objs = [("/", nothing, 0, ["name" => "segments"]), ("/'G'", nothing, 0, ["unit" => "V"]),
                    ("/'G'/'x'", Int16, 10, ["unit_string" => "V"])]
            tdms_segment(io, objs, reinterpret(UInt8, Int16[10s-9:10s;]))
        end
    end
    b = TDMSReader.readtdms(q)
    @test b["G", "x"].data == Int16[1:3000;]
    @test b.props["name"] == "segments" && b["G", "x"].props["unit_string"] == "V"
    @test @allocated(TDMSReader.readtdms(q)) < 300 * 16 * 1024
end

# TDMS stores a timestamp as (u64 fractions of 2^-64 s, i64 seconds since 1904), and
# TimeStamp's fields are (seconds, fractions): a bulk read must put them back in order.
tdms_bytes(t::TDMSReader.TimeStamp) = vcat(collect(reinterpret(UInt8, [t.fractions])), collect(reinterpret(UInt8, [t.seconds])))
tdms_bytes(x::Int16) = collect(reinterpret(UInt8, [x]))
@testset "TimeStamp channels" begin
    dir = mktempdir()
    ts = [TDMSReader.TimeStamp(3744278548, 0x8000000000000000), TDMSReader.TimeStamp(3744278549, 0x4000000000000000),
          TDMSReader.TimeStamp(1, 0x0000000000000000)]
    p = joinpath(dir, "timestamps.tdms")
    open(p, "w") do io
        tdms_segment(io, [("/", nothing, 0, []), ("/'G'", nothing, 0, []), ("/'G'/'t'", TDMSReader.TimeStamp, 3, [])],
                     reduce(vcat, tdms_bytes.(ts)))
    end
    @test TDMSReader.readtdms(p)["G", "t"].data == ts

    xs = Int16[7, -7, 70]                    # interleaved rows of (timestamp, Int16)
    q = joinpath(dir, "timestamps_interleaved.tdms")
    open(q, "w") do io
        objs = [("/", nothing, 0, []), ("/'G'", nothing, 0, []), ("/'G'/'t'", TDMSReader.TimeStamp, 3, []), ("/'G'/'x'", Int16, 3, [])]
        tdms_segment(io, objs, reduce(vcat, [vcat(tdms_bytes(t), tdms_bytes(x)) for (t, x) in zip(ts, xs)]); interleaved = true)
    end
    f = TDMSReader.readtdms(q)
    @test f["G", "t"].data == ts && f["G", "x"].data == xs
end
