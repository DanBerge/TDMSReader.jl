"Tables.jl for TDMS files: a group is a table whose columns are its channels."
module TDMSReaderTablesExt

using TDMSReader: Group
import Tables

Tables.istable(::Type{Group}) = true
Tables.columnaccess(::Type{Group}) = true
function Tables.columns(g::Group)
    lengths = unique(length(ch.data) for ch in values(g.channels))
    length(lengths) <= 1 || throw(ArgumentError("the channels of a group make a table only if they are " *
                                                "the same length; these hold $(join(lengths, ", ")) samples"))
    g
end
Tables.columnnames(g::Group) = Symbol.(collect(keys(g.channels)))
Tables.getcolumn(g::Group, i::Int) = g[i].data
Tables.getcolumn(g::Group, name::Symbol) = g[String(name)].data

end
