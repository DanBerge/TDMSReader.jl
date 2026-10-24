"FileIO for TDMS files: `load(\"x.tdms\")` is `readtdms(\"x.tdms\")`, keywords included."
module TDMSReaderFileIOExt

using TDMSReader: TDMSReader, readtdms
import FileIO

TDMSReader.fileio_load(f::FileIO.File{FileIO.DataFormat{:TDMS}}; kwargs...) = readtdms(FileIO.filename(f); kwargs...)
TDMSReader.fileio_load(s::FileIO.Stream{FileIO.DataFormat{:TDMS}}; kwargs...) = readtdms(FileIO.stream(s); kwargs...)

end
