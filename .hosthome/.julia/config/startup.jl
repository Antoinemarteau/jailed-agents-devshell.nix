# Package for IDE support
if isinteractive()
    import Pkg
    let env = joinpath(first(DEPOT_PATH), "environments", "nvim-lspconfig")
        mkpath(env)
        Pkg.activate(env)
        for pkg in ["LanguageServer", "SymbolServer", "StaticLint"]
            if Base.find_package(pkg) === nothing
                Pkg.add(pkg)
            end
        end
        Pkg.activate()
    end
end
