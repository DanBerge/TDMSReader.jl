# The package extensions: Tables.jl, Unitful and FileIO. Uses tdms_segment from runtests.jl.
using Tables, Unitful
import FileIO

# Group "G": an Int16 channel in volts and a Float64 channel; group "H": one Int16 channel.
function extensions_file(dir)
    p = joinpath(dir, "extensions.tdms")
    open(p, "w") do io
        objs = [("/'G'/'a'", Int16, 3, ["unit_string" => "V"]), ("/'G'/'b'", Float64, 3, []), ("/'H'/'c'", Int16, 2, [])]
        tdms_segment(io, objs, vcat(reinterpret(UInt8, Int16[1, 2, 3]), reinterpret(UInt8, [0.5, 1.5, 2.5]),
                                    reinterpret(UInt8, Int16[7, 8])))
    end
    p
end

@testset "a group is a table of its channels" begin
    f = readtdms(extensions_file(mktempdir()))
    g = f["G"]
    @test Tables.istable(g) && Tables.columnaccess(g)
    @test Tables.columntable(g) == (a = Int16[1, 2, 3], b = [0.5, 1.5, 2.5])
    @test Tables.columnnames(Tables.columns(g)) == [:a, :b]
    @test Tables.getcolumn(Tables.columns(g), 2) == [0.5, 1.5, 2.5]
    @test [r.b for r in Tables.rows(g)] == [0.5, 1.5, 2.5]
    push!(g["a"].data, 4)
    @test_throws ArgumentError Tables.columns(g)               # 4 samples beside 3
end

@testset "a channel's samples as quantities in its unit" begin
    f = readtdms(extensions_file(mktempdir()))
    a = f["G", "a"]                                            # unit_string "V"
    @test TDMSReader.withunits(a) == Int16[1, 2, 3] .* u"V"
    @test TDMSReader.withunits(f["G", "b"], u"m") == [0.5, 1.5, 2.5] .* u"m"
    @test_throws ArgumentError TDMSReader.withunits(f["G", "b"])           # no unit_string
    a.props["unit_string"] = "Volts"
    @test_throws ArgumentError TDMSReader.withunits(a)                     # not a unit Unitful reads
end

@testset "FileIO loads a TDMS file" begin
    # until FileIO's registry knows TDMS, register it here as the registry entry would
    FileIO.add_format(FileIO.format"TDMS", "TDSm", ".tdms", [:TDMSReader => Base.PkgId(TDMSReader).uuid])
    p = extensions_file(mktempdir())
    @test FileIO.query(p) isa FileIO.File{FileIO.format"TDMS"}
    @test FileIO.load(p) == readtdms(p)
    @test open(io -> FileIO.load(FileIO.Stream{FileIO.format"TDMS"}(io)), p) == readtdms(p)
    # FileIO prints the error before it rethrows it
    @test_throws Exception redirect_stderr(() -> FileIO.load(p; memory = 1), devnull)
end
