ENV["PYTHON"] = Sys.which("python") # For PyCall.jl / Plots

import Pkg as var"#Pkg"

if isnothing(Base.find_package("Revise"))
    var"#Pkg".add("Revise")
end

if isnothing(Base.find_package("TestEnv"))
    var"#Pkg".add("TestEnv")
end

if !isfile(joinpath(first(DEPOT_PATH), "bin", "kaimon"))
    var"#Pkg".Apps.add("Kaimon")
end

try
    using Revise
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end

# Kaimon Gate — auto-connect this REPL to the Kaimon dashboard.
# Uses the lightweight KaimonGate package. Activates only when KaimonGate is
# available in this environment, so other Julia versions or clean envs start
# silently — no warnings in sessions that don't have it.
if Base.identify_package("KaimonGate") !== nothing
    try
        @eval using Revise
    catch
    end
    try
        @eval using KaimonGate
        @eval KaimonGate.serve()
    catch e
        @warn "KaimonGate failed to start" exception = e
    end
end
# Kaimon Gate — end

