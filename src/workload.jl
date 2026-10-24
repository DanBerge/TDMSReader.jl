# What precompilation runs, so that the first read in a session is not spent compiling:
# the example files (contiguous and interleaved), read whole and on demand.
import PrecompileTools

PrecompileTools.@compile_workload begin
    for path in (_example_tdms, _example_incremental[6], joinpath(dirname(_example_tdms), "interleaved.tdms"))
        readtdms(path)
        info = tdmsinfo(path)
        for ((g, c), ci) in info.channels
            tdmsread(info, g, c, 1:ci.nsamples)
            tdmsblocks((x, offset) -> nothing, info, g, c; blocksize = 1)
        end
    end
end
