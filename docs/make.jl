using Documenter, TDMSReader

makedocs(;
    sitename = "TDMSReader.jl",
    modules = [TDMSReader],
    checkdocs = :exports,
    pages = ["Home" => "index.md", "Reference" => "reference.md"],
)

deploydocs(; repo = "github.com/DanBerge/TDMSReader.jl.git", devbranch = "master")
