using CUDA
using ExaPF
using KernelAbstractions
using Test
using Printf

import ExaPF: PowerSystem, LinearSolvers, TimerOutputs

# For debugging in REPL use the following lines
# empty!(ARGS)
# push!(ARGS, "BICGSTAB")
# push!(ARGS, "CUDADevice")
# push!(ARGS, "caseGO30R-025.raw")

# We do need the time in ms, and not with time units all over the place
function ExaPF.TimerOutputs.prettytime(t)
    value = t / 1e6 # "ms"

    if round(value) >= 100
        str = string(@sprintf("%.0f", value))
    elseif round(value * 10) >= 100
        str = string(@sprintf("%.1f", value))
    elseif round(value * 100) >= 100
        str = string(@sprintf("%.2f", value))
    else
        str = string(@sprintf("%.3f", value))
    end
    return lpad(str, 6, " ")
end

function printtimer(timers, key::String)
   prettytime(timers[key].accumulated_data.time)
end

linsolver = eval(Meta.parse("LinearSolvers.$(ARGS[1])"))
device = eval(Meta.parse("$(ARGS[2])()"))
datafile = joinpath(dirname(@__FILE__), ARGS[3])
if endswith(datafile, ".m")
    pf = PowerSystem.PowerNetwork(datafile, 1)
else
    pf = PowerSystem.PowerNetwork(datafile)
end
# Parameters
tolerance = 1e-6
polar = PolarForm(pf, device)
jac = ExaPF._state_jacobian(polar)
@show size(jac)
@show npartitions = ceil(Int64,(size(jac,1)/64))
precond = ExaPF.LinearSolvers.BlockJacobiPreconditioner(jac, npartitions, device)
# Retrieve initial state of network
x0 = ExaPF.initial(polar, State())
uk = ExaPF.initial(polar, Control())
p = ExaPF.initial(polar, Parameters())

algo = linsolver(precond)
xk = copy(x0)
nlp = ExaPF.ReducedSpaceEvaluator(polar, xk, uk, p;
                                    ε_tol=tolerance, linear_solver=algo)
convergence = ExaPF.update!(nlp, uk; verbose_level=ExaPF.VERBOSE_LEVEL_HIGH)
nlp.x .= x0                                   
convergence = ExaPF.update!(nlp, uk; verbose_level=ExaPF.VERBOSE_LEVEL_HIGH)
nlp.x .= x0                                   
ExaPF.reset_timer!(ExaPF.TIMER)
convergence = ExaPF.update!(nlp, uk; verbose_level=ExaPF.VERBOSE_LEVEL_HIGH)

# Make sure we are converged
@assert(convergence.has_converged)

# Output
prettytime = ExaPF.TimerOutputs.prettytime
timers = ExaPF.TIMER.inner_timers
inner_timer = timers["Newton"]
println("$(ARGS[1]), $(ARGS[2]), $(ARGS[3]),", 
        printtimer(timers, "Newton"),",",
        printtimer(inner_timer, "Jacobian"),",",
        printtimer(inner_timer, "Linear Solver"))
