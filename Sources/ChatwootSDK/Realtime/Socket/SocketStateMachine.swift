import Foundation

final class SocketStateMachine {
    private(set) var state: SocketConnectionState
    private(set) var desired: DesiredState = .stopped

    init(initial: SocketConnectionState) {
        self.state = initial
    }

    func transition(_ event: SocketMachineEvent, retryPlan: () -> RetryPlan) -> SocketTransition {
        if case .desiredChanged(let newDesired) = event {
            desired = newDesired
        }
        let result: SocketTransition
        switch state {
        case .disconnected:
            result = onDisconnected(event)
        case .connecting:
            result = onConnecting(event, retryPlan: retryPlan)
        case .connected:
            result = onConnected(event, retryPlan: retryPlan)
        case .waitingToRetry:
            result = onWaitingToRetry(event)
        case .disconnecting:
            result = onDisconnecting(event)
        }
        state = result.state
        return result
    }

    private func onDisconnected(_ event: SocketMachineEvent) -> SocketTransition {
        switch event {
        case .desiredChanged:
            switch desired {
            case .started:
                return reconnectTransition()
            case .stopped:
                return SocketTransition(state: .disconnected, effects: [])
            }
        default:
            return invalid(event)
        }
    }

    private func onConnecting(_ event: SocketMachineEvent, retryPlan: () -> RetryPlan) -> SocketTransition {
        switch event {
        case .desiredChanged:
            switch desired {
            case .stopped:
                return SocketTransition(state: .disconnecting, effects: [.cancelConnection])
            case .started:
                return invalid(event)
            }
        case .connectionOpened(let atMs):
            return SocketTransition(
                state: .connected(since: atMs),
                effects: [.publishStatus(.opened), .startWatchdog]
            )
        case .connectionClosed:
            return resolveAfterTermination(baseEffects: [.publishStatus(.closed)]) {
                scheduleRetryTransition(retryPlan)
            }
        case .connectionFailed:
            return resolveAfterTermination(baseEffects: [.publishStatus(.failed)]) {
                scheduleRetryTransition(retryPlan)
            }
        default:
            return invalid(event)
        }
    }

    private func onConnected(_ event: SocketMachineEvent, retryPlan: () -> RetryPlan) -> SocketTransition {
        switch event {
        case .desiredChanged:
            switch desired {
            case .stopped:
                return SocketTransition(
                    state: .disconnecting,
                    effects: [.closeConnection(code: normalClosureCode), .stopWatchdog]
                )
            case .started:
                return invalid(event)
            }
        case .connectionClosed:
            return resolveAfterTermination(baseEffects: [.publishStatus(.closed), .stopWatchdog]) {
                scheduleRetryTransition(retryPlan)
            }
        case .connectionFailed:
            return resolveAfterTermination(baseEffects: [.publishStatus(.failed), .stopWatchdog]) {
                scheduleRetryTransition(retryPlan)
            }
        case .forceReconnect:
            return SocketTransition(
                state: .disconnecting,
                effects: [.closeConnection(code: normalClosureCode)]
            )
        default:
            return invalid(event)
        }
    }

    private func onWaitingToRetry(_ event: SocketMachineEvent) -> SocketTransition {
        switch event {
        case .desiredChanged:
            switch desired {
            case .stopped:
                return SocketTransition(state: .disconnected, effects: [.cancelRetryTimer])
            case .started:
                return invalid(event)
            }
        case .retryTimerFired:
            return reconnectTransition()
        default:
            return invalid(event)
        }
    }

    private func onDisconnecting(_ event: SocketMachineEvent) -> SocketTransition {
        switch event {
        case .desiredChanged:
            return SocketTransition(state: state, effects: [])
        case .connectionClosed, .connectionFailed:
            return resolveAfterTermination(baseEffects: closeAnnouncement()) { reconnectTransition() }
        case .closeTimedOut:
            return resolveAfterTermination(baseEffects: [.cancelConnection] + closeAnnouncement()) { reconnectTransition() }
        default:
            return invalid(event)
        }
    }

    private func closeAnnouncement() -> [SocketSideEffect] {
        switch desired {
        case .stopped: return [.publishStatus(.closed)]
        case .started: return []
        }
    }

    private func resolveAfterTermination(
        baseEffects: [SocketSideEffect],
        ifStarted: () -> SocketTransition
    ) -> SocketTransition {
        switch desired {
        case .started:
            let transition = ifStarted()
            return SocketTransition(state: transition.state, effects: baseEffects + transition.effects)
        case .stopped:
            return SocketTransition(state: .disconnected, effects: baseEffects)
        }
    }

    private func reconnectTransition() -> SocketTransition {
        SocketTransition(state: .connecting, effects: [.openConnection])
    }

    private func scheduleRetryTransition(_ retryPlan: () -> RetryPlan) -> SocketTransition {
        let plan = retryPlan()
        return SocketTransition(
            state: .waitingToRetry(attempt: plan.attempt, delayMs: plan.delayMs),
            effects: [.scheduleRetry(attempt: plan.attempt, delayMs: plan.delayMs)]
        )
    }

    private func invalid(_ event: SocketMachineEvent) -> SocketTransition {
        SocketTransition(
            state: state,
            effects: [.logInvalidTransition(state: state.label, event: event.label)]
        )
    }
}
