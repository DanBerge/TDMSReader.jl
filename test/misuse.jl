# The API used the wrong way: what a careless caller gets. Each case must give a clear
# error naming the caller's mistake, or the right result. Uses tdms_segment from runtests.jl.

function misuse_file(dir)
    p = joinpath(dir, "misuse.tdms")
    open(io -> tdms_segment(io, [("/'G'/'a'", Int16, 1000, [])], reinterpret(UInt8, Int16.(1:1000))), p, "w")
    p
end

@testset "equal files, groups and channels hash alike" begin
    p = TDMSReader._example_incremental[6]
    a, b = readtdms(p), readtdms(p)
    @test a == b && isequal(a, b) && hash(a) == hash(b)
    @test hash(a["group"]) == hash(b["group"]) && hash(a["group", "channel1"]) == hash(b["group", "channel1"])
    @test length(unique([a, b])) == 1 && length(Set([a["group"], b["group"]])) == 1
    @test Dict(a => 1)[b] == 1
    @test readtdms(p) != readtdms(TDMSReader._example_tdms)
end

@testset "a stream that is closed or not open for reading" begin
    p = misuse_file(mktempdir())
    closed = open(p); close(closed)
    writing = open(tempname(), "w")
    for io in (closed, writing), call in (readtdms, tdmsinfo, io -> tdmsread(io, "G", "a", 1:2),
                                          io -> tdmsblocks((x, _) -> nothing, io, "G", "a"))
        e = try call(io); nothing catch e; e end
        @test e isa ArgumentError && occursin("not open for reading", e.msg)
    end
    close(writing)
    @test_throws SystemError readtdms(joinpath(mktempdir(), "missing.tdms"))
end

@testset "a block size or a range that reads nothing" begin
    p = misuse_file(mktempdir())
    for b in (0, -3)                                    # each used to loop for ever
        @test_throws ArgumentError tdmsblocks((x, _) -> nothing, p, "G", "a"; blocksize = b)
    end
    info = tdmsinfo(p)
    @test tdmsread(info, "G", "a", 1001:1000) == Int16[] && tdmsread(info, "G", "a", 1001:1000) isa Vector{Int16}
    @test tdmsread(info, "G", "a", 0:-1) == Int16[]
    @test_throws BoundsError tdmsread(info, "G", "a", 999:1001)
    @test_throws KeyError tdmsread(info, "G", "nope", 1:2)
end

@testset "tdmsblocks' f reading the same file or stream" begin
    p = misuse_file(mktempdir())
    for info in (tdmsinfo(p), tdmsinfo(IOBuffer(read(p))))
        got = Int16[]
        # every read starts by moving to its samples, so a read inside f leaves the blocks whole
        tdmsblocks(info, "G", "a"; blocksize = 64) do x, _
            @assert tdmsread(info, "G", "a", 1:3) == Int16[1, 2, 3]
            append!(got, x)
        end
        @test got == Int16.(1:1000)
    end
    @test_throws DomainError tdmsblocks((x, _) -> throw(DomainError(0)), p, "G", "a")   # f's error reaches the caller
end
