ENV["PYTHON"] = Sys.which("python") # For PyCall.jl / Plots

import Pkg as var"#Pkg"

if isnothing(Base.find_package("Revise"))
    var"#Pkg".add("Revise")
end

if isnothing(Base.find_package("Kaimon"))
    var"#Pkg".add("Kaimon")
end

if !isfile(joinpath(first(DEPOT_PATH), "bin", "kaimon"))
    var"#Pkg".Apps.add("Kaimon")
end

# Kaimon Gate — auto-connect this REPL to the TUI server
try
    using Revise
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end
try
    using Kaimon
    Gate.serve()
catch e
    @warn "Kaimon Gate failed to start" exception = e
end
