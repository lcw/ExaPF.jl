
function powerflow(
    polar::PolarForm{T, IT, VT, MT},
    jacobian::AutoDiff.Jacobian,
    buffer::PolarNetworkState{IT,VT},
    algo::NewtonRaphson;
    solver=DirectSolver(),
) where {T, IT, VT, MT}
    # Retrieve parameter and initial voltage guess
    Vm, Va, pbus, qbus = buffer.vmag, buffer.vang, buffer.pinj, buffer.qinj

    nbus = PS.get(polar.network, PS.NumberOfBuses())
    ngen = PS.get(polar.network, PS.NumberOfGenerators())
    npv = PS.get(polar.network, PS.NumberOfPVBuses())
    npq = PS.get(polar.network, PS.NumberOfPQBuses())
    n_states = get(polar, NumberOfState())
    nvbus = length(polar.network.vbus)
    ybus_re, ybus_im = get(polar.topology, PS.BusAdmittanceMatrix())

    ref = polar.indexing.index_ref
    pv = polar.indexing.index_pv
    pq = polar.indexing.index_pq

    # iteration variables
    iter = 0
    converged = false

    # indices
    j1 = 1
    j2 = npv
    j3 = j2 + 1
    j4 = j2 + npq
    j5 = j4 + 1
    j6 = j4 + npq

    # form residual function directly on target device
    F = buffer.balance
    dx = buffer.dx
    fill!(F, zero(T))
    fill!(dx, zero(T))

    println("[$iter] norm(Vm): ", xnorm(Vm), " norm(Va): ", xnorm(Va))
    # Evaluate residual function
    power_balance(polar, F, buffer)

    # check for convergence
    normF = xnorm(F)
    println("[$iter] norm(F): $normF")
    if algo.verbose >= VERBOSE_LEVEL_LOW
        @printf("Iteration %d. Residual norm: %g.\n", iter, normF)
    end
    if normF < algo.tol
        converged = true
    end

    linsol_iters = Int[]
    Vapv = view(Va, pv)
    Vapq = view(Va, pq)
    Vmpq = view(Vm, pq)
    dx12 = view(dx, j5:j6) # Vmqp
    dx34 = view(dx, j3:j4) # Vapq
    dx56 = view(dx, j1:j2) # Vapv

    @timeit TIMER "Newton" while ((!converged) && (iter < algo.maxiter))

        iter += 1

        @timeit TIMER "Jacobian" begin
            J = AutoDiff.jacobian!(polar, jacobian, buffer)
        end
        println("[$iter] norm(J): ", xnorm(J.nzVal))

        # Find descent direction
        if isa(solver, LinearSolvers.AbstractIterativeLinearSolver)
            @timeit TIMER "Preconditioner" LinearSolvers.update!(solver, J)
        end
        @timeit TIMER "Linear Solver" n_iters = LinearSolvers.ldiv!(solver, dx, J, F)
        push!(linsol_iters, n_iters)

        println("[$iter] norm(dx): ", xnorm(dx))
        # update voltage
        @timeit TIMER "Update voltage" begin
            # Sometimes it is better to move backward
            if (npv != 0)
                # Va[pv] .= Va[pv] .+ dx[j5:j6]
                Vapv .-= dx56
            end
            if (npq != 0)
                # Vm[pq] .= Vm[pq] .+ dx[j1:j2]
                Vmpq .-= dx12
                # Va[pq] .= Va[pq] .+ dx[j3:j4]
                Vapq .-= dx34
            end
        end
        println("[$iter] norm(Vm): ", xnorm(Vm)) 
        println("[$iter] norm(Va): ", xnorm(Va))

        fill!(F, zero(T))
        @timeit TIMER "Residual function" begin
            power_balance(polar, F, buffer)
        end

        @timeit TIMER "Norm" normF = xnorm(F)
        println("[$iter] norm(F): $normF")
        if algo.verbose >= VERBOSE_LEVEL_LOW
            @printf("Iteration %d. Residual norm: %g.\n", iter, normF)
        end

        if normF < algo.tol
            converged = true
        end
    end

    if algo.verbose >= VERBOSE_LEVEL_HIGH
        if converged
            @printf("N-R converged in %d iterations.\n", iter)
        else
            @printf("N-R did not converge.\n")
        end
    end

    # Timer outputs display
    if algo.verbose >= VERBOSE_LEVEL_MEDIUM
        show(TIMER)
        println("")
    end
    return ConvergenceStatus(converged, iter, normF, sum(linsol_iters))
end

