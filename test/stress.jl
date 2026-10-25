# Long records: a 100 MB channel and a file of 1000 segments in every run, and a channel
# past 2^31 bytes when TDMSREADER_STRESS=1. The samples follow a formula and are written in
# chunks, so no copy of them is ever held whole and any window can be checked.

stresscode(i) = reinterpret(Int16, UInt16((Int64(i) * 7919) & 0xffff))

"Write a segment of one Int16 channel `/'G'/'x'` holding samples `first:first+n-1`."
function stress_segment(io, n, first)
    meta = IOBuffer()
    path = "/'G'/'x'"
    write(meta, UInt32(1), UInt32(ncodeunits(path)), codeunits(path), UInt32(20), UInt32(2), UInt32(1), UInt64(n), UInt32(0))
    m = take!(meta)
    write(io, b"TDSm", UInt32(1 << 1 | 1 << 2 | 1 << 3), UInt32(4713), UInt64(length(m) + 2n), UInt64(length(m)), m)
    buf = Vector{Int16}(undef, min(n, 1 << 22))
    for start in 0:length(buf):n-1
        k = min(length(buf), n - start)
        for j in 1:k
            buf[j] = stresscode(first + start + j - 1)
        end
        write(io, view(buf, 1:k))
    end
end

# the least of three readings, as @allocated can count other threads' work
least_alloc(f) = minimum(_ -> (@allocated f()), 1:3)

function check_long(p, n; whole = true)
    info = tdmsinfo(p)
    @test info["G", "x"].nsamples == n
    r = (n - 9_999):n                       # a window at the far end, skipped to, not read through
    @test tdmsread(info, "G", "x", r) == stresscode.(r)
    @test least_alloc(() -> tdmsread(info, "G", "x", r)) < 2length(r) + 100_000
    s = Ref(0)                              # one pass in blocks, in the memory of one block
    @test tdmsblocks((x, _) -> (s[] += sum(Int, x)), info, "G", "x"; blocksize = 2^20) == n
    @test s[] == sum(k -> Int(stresscode(k)), 1:n)
    # the block's buffer, and short-lived views of it (about 200 bytes a block), nothing kept
    @test least_alloc(() -> tdmsblocks((x, _) -> nothing, info, "G", "x"; blocksize = 2^16)) <
          2^17 + 1024 * cld(n, 2^16) + 100_000
    @test_throws ErrorException readtdms(p; memory = 2n - 1)       # refused before it allocates
    @test least_alloc(() -> try readtdms(p; memory = 2n - 1) catch end) < 100_000
    if whole
        x = readtdms(p)["G", "x"].data
        @test length(x) == n && all(k -> x[k] == stresscode(k), 1:n)
        x = nothing
        @test least_alloc(() -> readtdms(p)) < 2n + (1 << 20)       # the data once
    end
end

@testset "a 100 MB channel" begin
    n = 50_000_000
    p = joinpath(mktempdir(), "long.tdms")
    open(io -> stress_segment(io, n, 1), p, "w")
    check_long(p, n)
    rm(p); GC.gc()
end

@testset "a file of 1000 segments" begin
    nseg, m = 1000, 10_000
    p = joinpath(mktempdir(), "segments.tdms")
    open(p, "w") do io
        for s in 0:nseg-1
            stress_segment(io, m, s * m + 1)
        end
    end
    info = tdmsinfo(p)
    @test info["G", "x"].nsamples == nseg * m && length(info["G", "x"].runs) == nseg
    @test tdmsread(info, "G", "x", (m - 1):(m + 2)) == stresscode.((m - 1):(m + 2))   # across a segment boundary
    @test readtdms(p)["G", "x"].data == stresscode.(1:nseg * m)
    rm(p)
end

if get(ENV, "TDMSREADER_STRESS", "") == "1"
    @testset "a channel past 2^31 bytes" begin
        n = 2^30 + 1000                     # 2 GiB of Int16 and more: offsets past 2^31
        p = joinpath(mktempdir(), "huge.tdms")
        open(io -> stress_segment(io, n, 1), p, "w")
        check_long(p, n; whole = false)      # whole would need 2 GiB of memory
        rm(p)
    end
end
