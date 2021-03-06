mutable struct DiffEqSystem <: AbstractSystem
    eqs::Vector{Equation}
    ivs::Vector{Variable}
    dvs::Vector{Variable}
    ps::Vector{Variable}
    jac::Matrix{Expression}
end

DiffEqSystem(eqs, ivs, dvs, ps) = DiffEqSystem(eqs, ivs, dvs, ps, Matrix{Expression}(undef,0,0))

function DiffEqSystem(eqs)
    predicates = [_is_derivative, _is_dependent]
    _, dvs = extract_elements(eqs, predicates)
    ivs = unique(vcat((dv.dependents for dv ∈ dvs)...))
    ps, = extract_elements(eqs, [_is_parameter(ivs)])
    DiffEqSystem(eqs, ivs, dvs, ps, Matrix{Expression}(undef,0,0))
end

function DiffEqSystem(eqs, ivs)
    predicates = [_is_derivative, _is_dependent, _is_parameter(ivs)]
    _, dvs, ps = extract_elements(eqs, predicates)
    DiffEqSystem(eqs, ivs, dvs, ps, Matrix{Expression}(undef,0,0))
end

function generate_ode_function(sys::DiffEqSystem;version = ArrayFunction)
    var_exprs = [:($(sys.dvs[i].name) = u[$i]) for i in eachindex(sys.dvs)]
    param_exprs = [:($(sys.ps[i].name) = p[$i]) for i in eachindex(sys.ps)]
    sys_exprs = build_equals_expr.(sys.eqs)
    if version == ArrayFunction
        dvar_exprs = [:(du[$i] = $(Symbol("$(sys.dvs[i].name)_$(sys.ivs[1].name)"))) for i in eachindex(sys.dvs)]
        exprs = vcat(var_exprs,param_exprs,sys_exprs,dvar_exprs)
        block = expr_arr_to_block(exprs)
        :((du,u,p,t)->$(toexpr(block)))
    elseif version == SArrayFunction
        dvar_exprs = [:($(Symbol("$(sys.dvs[i].name)_$(sys.ivs[1].name)"))) for i in eachindex(sys.dvs)]
        svector_expr = quote
            E = eltype(tuple($(dvar_exprs...)))
            T = StaticArrays.similar_type(typeof(u), E)
            T($(dvar_exprs...))
        end
        exprs = vcat(var_exprs,param_exprs,sys_exprs,svector_expr)
        block = expr_arr_to_block(exprs)
        :((u,p,t)->$(toexpr(block)))
    end
end

isintermediate(eq::Equation) = eq.lhs.diff === nothing

function build_equals_expr(eq::Equation)
    @assert typeof(eq.lhs) <: Variable

    lhs = eq.lhs.name
    isintermediate(eq) || (lhs = Symbol(lhs, :_, "$(eq.lhs.diff.x.name)"))

    return :($lhs = $(convert(Expr, eq.rhs)))
end

function calculate_jacobian(sys::DiffEqSystem, simplify=true)
    calcs, diff_exprs = partition(isintermediate, sys.eqs)
    rhs = [eq.rhs for eq in diff_exprs]

    # Handle intermediate calculations by substitution
    for calc ∈ calcs
        find_replace!.(rhs, calc.lhs, calc.rhs)
    end

    sys_exprs = calculate_jacobian(rhs, sys.dvs)
    sys_exprs = Expression[expand_derivatives(expr) for expr in sys_exprs]
    sys_exprs
end

function generate_ode_jacobian(sys::DiffEqSystem, simplify=true)
    var_exprs = [:($(sys.dvs[i].name) = u[$i]) for i in eachindex(sys.dvs)]
    param_exprs = [:($(sys.ps[i].name) = p[$i]) for i in eachindex(sys.ps)]
    diff_exprs = filter(!isintermediate, sys.eqs)
    jac = calculate_jacobian(sys, simplify)
    sys.jac = jac
    jac_exprs = [:(J[$i,$j] = $(convert(Expr, jac[i,j]))) for i in 1:size(jac,1), j in 1:size(jac,2)]
    exprs = vcat(var_exprs,param_exprs,vec(jac_exprs))
    block = expr_arr_to_block(exprs)
    :((J,u,p,t)->$(block))
end

function generate_ode_iW(sys::DiffEqSystem, simplify=true)
    var_exprs = [:($(sys.dvs[i].name) = u[$i]) for i in eachindex(sys.dvs)]
    param_exprs = [:($(sys.ps[i].name) = p[$i]) for i in eachindex(sys.ps)]
    diff_exprs = filter(!isintermediate, sys.eqs)
    jac = sys.jac

    gam = Parameter(:gam)

    W = LinearAlgebra.I - gam*jac
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW = inv(W)

    if simplify
        iW = simplify_constants.(iW)
    end

    W = inv(LinearAlgebra.I/gam - jac)
    W = SMatrix{size(W,1),size(W,2)}(W)
    iW_t = inv(W)
    if simplify
        iW_t = simplify_constants.(iW_t)
    end

    iW_exprs = [:(iW[$i,$j] = $(convert(Expr, iW[i,j]))) for i in 1:size(iW,1), j in 1:size(iW,2)]
    exprs = vcat(var_exprs,param_exprs,vec(iW_exprs))
    block = expr_arr_to_block(exprs)

    iW_t_exprs = [:(iW[$i,$j] = $(convert(Expr, iW_t[i,j]))) for i in 1:size(iW_t,1), j in 1:size(iW_t,2)]
    exprs = vcat(var_exprs,param_exprs,vec(iW_t_exprs))
    block2 = expr_arr_to_block(exprs)
    :((iW,u,p,gam,t)->$(block)),:((iW,u,p,gam,t)->$(block2))
end

function DiffEqBase.ODEFunction(sys::DiffEqSystem;version = ArrayFunction,kwargs...)
    expr = generate_ode_function(sys;version=version,kwargs...)
    if version == ArrayFunction
      ODEFunction{true}(eval(expr))
    elseif version == SArrayFunction
      ODEFunction{false}(eval(expr))
    end
end


export DiffEqSystem, ODEFunction
export generate_ode_function
