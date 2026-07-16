ENV["PYTHON"] = Sys.which("python") # For PyCall.jl / Plots

if isinteractive()
    ENV["JULIA_EDITOR"] = "nvim"

    import Pkg as var"#Pkg"
    let
        pkgs = [
            "BasicAutoloads", "Revise", "OhMyREPL",
            "BenchmarkTools", "Chairmarks", "Cthulhu", "Debugger",
            "Profile", "ProfileView", "Test", "StaticArrays",
            "LinearAlgebra", "About", "Pluto", "FillArrays",
            "Kaimon", "KaimonGate", "TestEnv"
        ]
        for pkg in pkgs
            if Base.find_package(pkg) === nothing
                var"#Pkg".add(pkg)
            end
        end

        # JETLS.jl
        #if isnothing(var"#Pkg".App.status( var"#Pkg".PackageSpec("JETLS")))
        ## This either installs or updates JETLS
        #redirect_stderr(devnull) do # makes it silent
        #  var"#Pkg".Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-02-27")
        #end
        #end

        # LanguageServer.jl
        # it should be installed in special folder for neovim
        mkpath(joinpath(first(DEPOT_PATH), "environments", "nvim-lspconfig"))
        var"#Pkg".activate(joinpath(first(DEPOT_PATH), "environments", "nvim-lspconfig"))
        if isnothing(Base.find_package("LanguageServer"))
            var"#Pkg".add("LanguageServer")
        end
        if isnothing(Base.find_package("SymbolServer"))
            var"#Pkg".add("SymbolServer")
        end
        if isnothing(Base.find_package("StaticLint"))
            var"#Pkg".add("StaticLint")
        end
        var"#Pkg".activate()
    end

    using Revise

    if isfile("Project.toml") #&& isfile("Manifest.toml")
        var"#Pkg".activate(".")
    end

    import BasicAutoloads
    BasicAutoloads.register_autoloads([
        ["@btime", "@benchmark"] => :(using BenchmarkTools),
        ["@b", "@be"]            => :(using Chairmarks),
        ["@test", "@testset", "@test_broken", "@test_deprecated", "@test_logs",
        "@test_nowarn", "@test_skip", "@test_throws", "@test_warn", "@inferred"]
                                 => :(using Test),
        ["@descend", "@descend_code_typed", "@descend_code_warntype"] =>
                                    :(using Cthulhu),
        ["@enter", "@run"]       => :(using Debugger),
        ["@profile"]             => :(using Profile),
        ["@profview", "@profview_allocs"]
                                 => :(using ProfileView),
        ["norm", "I"]            => :(using LinearAlgebra),
        ["about"]                => :(using About),
        ["MVector", "SVector", "MMatrix", "SMatrix", "MArray", "SArray"] =>
                                    :(using StaticArrays),

       #["pager"]                => :(using TerminalPager),
       #["cowsay"]               => :(cowsay(x) = println("Cow: \"$x\"")),
    ])
end

import Pkg as var"#Pkg"

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
        @eval using KaimonGate
        @eval KaimonGate.serve()
    catch e
        @warn "KaimonGate failed to start" exception = e
    end
end
# Kaimon Gate — end

