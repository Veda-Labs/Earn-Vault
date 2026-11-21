# Veda shared-vault stacks

This page owns the contracts that build many Earn stacks on one BoringVault without a transaction
from the vault's administrator for each stack: `VedaVaultRegistry`, `VedaLockstepEngine`,
`VedaStackFactory` with its two deployers, and the two ways the factory's authorizations reach Veda,
`VedaRoleGranter` and `VedaAuthorityOverlay` with `VedaVaultAccessRegistry`. Valuation, immediate and
queued exits, request data, and stale reports are the [Veda engine](veda.md)'s and are not repeated
here.

None of these contracts is audited ([audits](../audit/README.md#scope)). They live beside the
audited `VedaEngine`, `VedaPeripheryRegistry` and `VedaForwardingSolver`, which are unchanged and
keep serving the stacks built on them. The profile lifecycle (`pnpm earn`) neither deploys nor
inspects a stack built here: its Veda inspection reads `VedaEngine`'s per-engine registry, which a
`VedaLockstepEngine` does not have.

## What changes

A `VedaEngine` stack needs the vault's administrator twice: the BoringVault's owner publishes and
binds a registry for that one engine, and the RolesAuthority's owner gives the engine its role. Here
the administrator acts once per vault. It publishes the vault's modules in one registry that every
engine reads, and empowers one factory. After that an operator builds each stack, and the factory
authorizes only what it built.

| Contract                                                                                                                                                                                 | Count     | Purpose                                                                     |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------------- |
| [`VedaVaultRegistry`](../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol)                                                                                                       | Per vault | The vault's Teller, optional Queue with its stock solver, and Accountant    |
| [`VedaLockstepEngine`](../../../src/earn/engines/veda/shared/VedaLockstepEngine.sol)                                                                                                     | Per stack | `VedaEngine` that reads the registry on every call                          |
| [`VedaStackFactory`](../../../src/earn/engines/veda/shared/VedaStackFactory.sol)                                                                                                         | Per vault | Operator-gated: builds, binds, authorizes and records a stack               |
| [`VedaLockstepEngineDeployer`, `VedaForwardingSolverDeployer`](../../../src/earn/engines/veda/shared/VedaStackDeployers.sol)                                                             | Per chain | Hold the engine's and the forwarding solver's creation code for the factory |
| [`VedaRoleGranter`](../../../src/earn/engines/veda/shared/VedaRoleGranter.sol)                                                                                                           | Per vault | Authorization by RolesAuthority roles (the default)                         |
| [`VedaAuthorityOverlay`](../../../src/earn/engines/veda/shared/VedaAuthorityOverlay.sol), [`VedaVaultAccessRegistry`](../../../src/earn/engines/veda/shared/VedaVaultAccessRegistry.sol) | Per vault | Authorization by a read-only overlay (the alternative)                      |

**The vault's administrator** is the BoringVault's owner, or the owner of the BoringVault's current
authority. Both can already take custody of the vault, so naming them adds no trust root. Both are
read live (`isVaultAdmin`): the administrator follows an ownership transfer and a replaced
RolesAuthority, a role never satisfies it, and the zero address never does. On a finalized vault,
whose owner is zero, the administrator is the timelock that owns the RolesAuthority.

## Vault registry

The registry is ownerless and immutable to one BoringVault and base asset. Only the administrator
calls `publish(teller, queue, accountant, solver, minRate, maxRate, maxReportAge)`. A Queue and its
stock solver are published together, or both are zero for an immediate-only vault.

**A publication reaches every engine of the vault in the same call.** No engine owner pauses
deposits, supplies rate bounds, or activates anything, so publication runs the checks an engine used
to run and refuses a tuple unless:

- every module has code, the Teller and a nonzero Queue report this BoringVault and the new
  Accountant, the Accountant reports this BoringVault and the base asset, and the stock solver is
  none of those contracts;
- a nonzero Queue has onchain tracking enabled;
- the Teller is the vault's owner or its authority allows it `enter` and `exit`, because a Teller
  that cannot mint and burn would stop every stack's deposits and immediate exits at once;
- the Accountant's report age is readable through one of the two supported surfaces
  ([valuation and freshness](veda.md#valuation-and-freshness)), nonzero, not in the future, and no
  older than `maxReportAge`; and
- the Accountant's safe rate lies within `[minRate, maxRate]`.

These checks do not show that a module's code is benign, that the stock solver holds its Veda
permissions, or that the Earn stacks are admitted to the new modules
([publications](#publications)). The rate bounds are the caller's: `1` and the maximum waive the
check. A rate that jumps inside the bounds is priced by every stack at once, and an upward jump makes
each stack's `EarnFees` charge fees on a gain that did not happen, which a corrective publication
does not undo. Schedule a publication with bounds tight around the outgoing Accountant's rate.

## Lockstep engine

`VedaLockstepEngine` holds one EarnVault's BoringVault shares exactly as `VedaEngine` does. Its
vault, registry and base asset are immutable. It differs in these ways only:

- **No cached modules.** `teller()`, `queue()` and `accountant()` read the registry. There is no
  `syncVedaPeriphery`, and the engine advertises `IEarnEngineAsyncRedeem` exactly while the registry
  publishes a Queue.
- **No registry binding.** `initializeEarnVault` is owner-only and set-once but needs no reciprocal
  registry entry. An engine is useful only once it is authorized on the Teller and Queue.
- **Construction** requires only a published registry. The registry validates each tuple it
  publishes, so the constructor checks no wiring or report age.
- **Claims and counts.** A claim still records its originating Queue, so a publication strands
  neither a cancellation nor a settlement. `openClaimsByQueue` covers every Queue alike.
- **One standing share allowance.** The one-unit allowance follows the Queue of the latest request:
  the next request on a newly published Queue clears the previous one, and anyone may clear it
  sooner with `clearRetiredQueueAllowance`. A request also requires the Queue to leave exactly that
  unit.
- **Fee freshness fails soft.** `isFeeValuationFresh` returns false, instead of reverting, when the
  Accountant's report age cannot be read, so such an Accountant defers fees without blocking an exit.
  Deposits still fail closed (`UnsupportedAccountantFreshness`).

The engine approves the immutable BoringVault, never the Teller, and measures every share and asset
movement. A wrong Teller can therefore move the engine's assets only into the vault and must mint a
measured share increase; a wrong Queue can take exactly the requested shares and must return a
matching tracked request. A transaction that prices one engine operation and then meets a
publication quoting another rate reverts (`RateChangedWithinTransaction`).

The engine's owner keeps only wrapper-local settings: `setMaxRateAge`, `setAuthorizedForwarder`,
`recoverExternalSettlement` and `sweepDust`, with the bounds [Veda](veda.md#vedaengine) gives them.

## Stack factory

`VedaStackFactory` is immutable to one registry, one authorizer, the canonical `EarnFactory`, the two
deployers, and the owner and treasury of every forwarding solver it builds. `EarnFactory` and both
deployers are pinned by address and by the code hash named at construction.

`createStack(engineParams, core, newTransferPolicyAdmin)`, callable only by the operator:

1. deploys a `VedaLockstepEngine` through the pinned deployer, owned by the factory;
2. calls `EarnFactory.deploy(core)` with that engine, creating the EarnVault, EarnShare and EarnFees
   ([contract reference](../reference/contracts.md#earnfactory));
3. when the vault publishes a Queue, deploys a `VedaForwardingSolver` for this engine against the
   published Queue, Teller and stock solver, and authorizes it on the engine;
4. calls `initializeEarnVault(earnVault, core.owner)`, binding the engine to the EarnVault the
   canonical factory just produced and handing it to the stack's owner in the same call;
5. authorizes the engine and the forwarding solver through the authorizer, then requires that each
   is actually allowed its calls by the module's own authority; and
6. records the stack (`stack(engine)`) and emits `StackCreated`.

`core` is the canonical `EarnFactory.DeployParams` with `engine` left zero. `core.owner` becomes the
EarnVault's operator and the engine's owner. `core.transferPolicyId` is attached as given, with zero
meaning unrestricted; a nonzero `newTransferPolicyAdmin` instead creates a TIP-403 whitelist
administered by that address and attaches it. A protected stack is unusable until its policy's
administrator authorizes the [required members](access.md#required-members).

The factory builds nothing until the administrator names it on its authorizer
(`AuthorizerNotBound`). It authorizes only contracts it built itself. Checking an engine's code
would not be enough, because a canonical engine lets its owner bind any EarnVault: the factory owns
each engine from construction until it binds it, and refuses any engine it did not deploy in its own
call (`EngineNotPending`), including one made through the public deployer with the factory named as
owner.

**One call or two.** `deployEngine` followed by `finalizeStack` builds the same stack in two
transactions; in between, the engine is owned by the factory, bound to nothing and authorized for
nothing. Under Tempo's T8 pricing, with the fixture TIP-20 factory and Veda modules, `createStack`
measures about 28.3M gas on a vault with a Queue and 23.0M without, against the 30M per-transaction
cap; `deployEngine` measures 12.6M and `finalizeStack` 15.7M. Use the two-call path on a vault with a
Queue unless a fork test against the live precompiles shows the one-call margin holds.
`EarnFactory` is open to anyone, so someone who sees a pending `finalizeStack` can create the same
core first and make it revert; finalize again under another `deploymentId`. Such a core is bound to
nothing and holds nothing.

| Caller        | Functions                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------- |
| Operator      | `createStack`, `deployEngine`, `finalizeStack`, `deployForwarder`                                     |
| Pausers       | `revokeEngine`, `revokeForwarder`, `pauseRegistrations`                                               |
| Administrator | The pausers' functions, `reinstateEngine`, `reinstateForwarder`, `resumeRegistrations`, `setOperator` |

Pausers are the accounts the BoringVault's authority allows to call that function on the factory;
the administrator grants those capabilities to the vault's pause roles. Pausing and revoking only
reduce what the factory and its stacks can do. A paused factory refuses every operator call.

The records say what the factory last did, not what is permitted now: the administrator can change a
permission directly, and a function the vault lets anyone call stays callable by a revoked engine.
`stack(engine).forwarder` is the forwarding solver built with the stack, and a later
`deployForwarder` does not change it; `ForwarderDeployed` lists every forwarder, and the engine's
`authorizedForwarder` says which ones its owner admitted.

## Authorization

A factory writes each authorization through one `IVedaStackAuthorizer`. Two exist. Use the role
granter unless the vault's administrator will not let any contract write to its RolesAuthority.

Either authorizer accepts only the factories the administrator names (`setFactory(factory, true)`),
and names one only if it reports that authorizer and that authorizer's registry as its own. An engine
trusts its registry for every module, so a factory that builds on some other registry must never
receive the vault's authorizations; this check stops one from being named by mistake. It is a check
of wiring, not of code: the administrator still reviews the factory it names. Several factories can
be named at once ([replacing the factory](#replacing-the-factory)).

|                             | Role granter                                              | Overlay                                                                    |
| --------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------- |
| An authorization is         | A role on the RolesAuthority                              | A flag in `VedaVaultAccessRegistry`                                        |
| Live contracts changed      | The RolesAuthority's `authority`                          | The `authority` of the Teller, every Queue and every stock solver          |
| Worst bug                   | Any role to anyone: custody of the vault                  | A wrong answer for a call on the Teller, a Queue or a stock solver         |
| If the new contract fails   | Grants and revocations stop; nothing else is affected     | Those modules stop until replaced, since only the overlay can repoint them |
| Role numbers and table rows | Two roles and their capabilities on each published module | None                                                                       |
| Existing tooling            | Reads the RolesAuthority as before                        | Must read each module's own `authority`                                    |

### Role granter

A RolesAuthority gates by function, not by argument: whoever may call `setUserRole` may give any
role to anyone. `VedaRoleGranter` narrows that in code. The administrator points the RolesAuthority's
own `authority` at the granter, whose `canCall` admits one triple: the granter, calling
`setUserRole`, on that RolesAuthority. The owner keeps every power, no role number is spent on a
registrar, and no capability row that targets the RolesAuthority becomes live, because the
RolesAuthority does not consult its own role table for calls on itself.

The granter's RolesAuthority, registry, vault and two role numbers are immutable, its only writes
are `setUserRole` for those two roles, and only a factory the RolesAuthority's owner named calls it.
Before a grant it also requires that:

- it is still the RolesAuthority's authority, so the owner and the granter are the only paths to the
  role table;
- the RolesAuthority still has an owner, who could cut it off;
- the BoringVault answers to that RolesAuthority; and
- the role has no capability on the BoringVault's `manage`, `enter`, `exit`,
  `setBeforeTransferHook`, `setAuthority` or `transferOwnership`, nor on the RolesAuthority's
  `setUserRole`, `setRoleCapability`, `setPublicCapability`, `setAuthority` or `transferOwnership`.

Revocation skips those checks so that it works whenever the RolesAuthority admits it. A role number
that collides with a capability elsewhere (a manager, an Accountant) is not detected; it is harmless
only because the holders are the fixed-code engines and forwarding solvers the factory builds, so
choose two role numbers nothing else uses.

Pointing the RolesAuthority's `authority` elsewhere stops new grants and the granter's revocations
alike. Roles already granted stay until the owner clears them or removes the roles' capabilities, so
pause and revoke through the factory first.

### Overlay

Nothing writes to the RolesAuthority. The Teller, each Queue and each stock solver ask their own
`authority` whether a caller may call a function; the administrator points those at a
`VedaAuthorityOverlay`, and the BoringVault keeps the RolesAuthority. The overlay has no owner and
no storage:

1. it returns true whenever the RolesAuthority allows the call, before reading anything else, so
   every permission that RolesAuthority gives, including the one that repoints an authority, depends
   on nothing new;
2. otherwise it asks `VedaVaultAccessRegistry.canStackCall`, and treats a revert, missing code or
   any answer but a well-formed true as a denial.

`canStackCall` allows an active engine `bulkDeposit` and `bulkWithdraw` on the published Teller and
`requestOnChainWithdraw` and `cancelOnChainWithdrawUsingRequestId` on an honored Queue, and an active
forwarding solver `boringRedeemSolve` on an honored stock solver. It never answers for the
BoringVault. A Queue and its stock solver are honored from publication until the administrator
retires them (`setQueueHonored`, `setSolverHonored`), which it must not do while any engine's
`openClaimsByQueue` for that Queue is nonzero; honoring one again undoes a mistake without
republishing it.

`VedaVaultAccessRegistry` is the vault registry plus that record. Only a factory the
administrator named writes it. The registry creates the overlay itself
(`createOverlay`, open to anyone, at the address `predictOverlay` reports) and binds only an overlay
it created, for the RolesAuthority the BoringVault answers to now (`setOverlay`), so the overlay's
code needs no separate review. While an overlay is bound, a publication is refused unless its
Teller, Queue and stock solver already answer to it, and unless the overlay still passes through the
vault's RolesAuthority.

## Setup

Deploy the deployers once per chain. Per vault, anyone deploys the registry, the authorizer and the
factory; none holds a permission until the administrator's one batch, which a new vault's deployer
runs before handing the vault over. Before that batch, review:

- the verified code of the registry, the authorizer and the factory, since the onchain checks cover
  their wiring and never their code;
- the factory's `registry`, `authorizer`, `operator`, `forwarderOwner`, `forwarderTreasury` and three
  pinned code hashes, against the registry being published on and the reviewed release; and
- with the role granter, its `rolesAuthority`, `registry` and two role numbers.

Both variants:

1. `registry.publish(...)` with the vault's live modules.
2. Give the vault's pause roles the factory's `revokeEngine`, `revokeForwarder` and
   `pauseRegistrations`.

Role granter. Confirm the RolesAuthority's `authority` is zero, since setting it displaces whatever
was there.

1. Give the Earn engine role `bulkDeposit` and `bulkWithdraw` on the Teller and, with a Queue,
   `requestOnChainWithdraw` and `cancelOnChainWithdrawUsingRequestId` on it.
2. Give the Earn forwarder role `boringRedeemSolve` on the stock solver.
3. `rolesAuthority.setAuthority(granter)`, then `granter.setFactory(factory, true)`.
4. `granter.assertSetup(registry, factory)`, naming the registry published in this batch. It reverts
   the batch unless the granter was built for that registry, the factory is named, and every
   pre-grant check passes for both roles.

Overlay. Deploy `VedaVaultAccessRegistry` as the registry and call `createOverlay()`. Confirm the
Teller, the Queue and the stock solver each answer to the vault's RolesAuthority now: the overlay
passes that RolesAuthority through, and a permission another authority gave would be lost.

1. `setAuthority(overlay)` on the Teller, the Queue and the stock solver.
2. `registry.setOverlay(overlay)`, which requires the published modules to answer to the overlay,
   then `registry.setFactory(factory, true)`.

## Operations

### Publications

Every publication is the administrator's and reaches every stack at once, with no staging. Alongside
it:

- admit the Earn stacks to the new modules: with the role granter, add the Earn roles' capabilities
  on them in the same batch; with the overlay, point them at the overlay first;
- give the new modules their own Veda permissions, including the stock solver's;
- after a change of Queue, stock solver or Teller, have the operator call `deployForwarder(engine)`
  for each stack and each stack's owner call `setAuthorizedForwarder` on its engine. A forwarding
  solver fixes all three at construction, so until both steps are done, requests filed on the new
  Queue cannot be settled; and
- keep a replaced Queue, its stock solver, its Teller and the stacks' old forwarding solvers live
  until `openClaimsByQueue(queue)` is zero on every engine. The factory builds a forwarding solver
  only for the tuple published now.

### Incidents

- **A leaked operator key.** Call `pauseRegistrations` first: it stops every operator call at once.
  Then revoke the engines that key built, and have the administrator replace the operator
  (`setOperator`) before it resumes registrations.
- **One stack.** `revokeEngine` stops its deposits and immediate exits, and its queued requests and
  cancellations unless the vault lets anyone call those. Its users cannot exit instantly until the
  administrator reinstates it, so a false alarm costs them the administrator's delay.
- **The whole vault.** Pause the Teller as before; these contracts do not change that.

### Replacing the factory

A factory is pinned to exact engine and core code, so a new release means a new factory, deployed
against the same registry and authorizer and named by the administrator beside the old one. Each
factory reaches only the stacks it built. Keep the old factory named for as long as its stacks
exist: its pausers revoke them, its operator builds their forwarding solvers after a publication,
and the administrator reinstates them, all through it. Pause its registrations so that it builds no
new stacks.

Once the administrator stops naming a factory, that factory can change nothing. Its stacks keep
their authorizations and keep working, but they cannot get a forwarding solver for a newly published
Queue, and only the administrator can revoke them: with `setUserRole` on the RolesAuthority, or with
`revokeAccess` on the access registry. Either leaves the factory's own record unchanged.

## Trust and failure modes

None of these contracts is the vault's owner or can reach `manage`, `enter`, `exit`, `setAuthority`
or `transferOwnership` on it.

| If this fails                 | Worst case                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Operator key leaks            | Stacks with an owner, fees, controls, rate age bound and transfer policy of the attacker's choice. Their deposits and exits skip the Teller's share lock, so their owner can enter before a rate update and leave after it, which dilutes every holder of the BoringVault. Also forwarding solvers for existing stacks, which settle nothing until an engine's owner admits them. No role, no registry, no other stack's settings, no custody. |
| Factory has a bug             | An authorization for an address that is not a genuine engine or forwarding solver: the same access as above, and for a forwarder, solving requests on the vault's Queue                                                                                                                                                                                                                                                                        |
| Role granter has a bug        | Any role to anyone, which is custody of the vault. Nothing bounds it but its code.                                                                                                                                                                                                                                                                                                                                                             |
| Overlay or its registry fails | A wrong answer for a call on the Teller, a Queue or a stock solver. A reverting RolesAuthority is the only way it denies an existing permission.                                                                                                                                                                                                                                                                                               |
| Pauser is compromised         | Every stack revoked and registrations paused until the administrator restores them. No funds move.                                                                                                                                                                                                                                                                                                                                             |
| A stack's owner is malicious  | Misuse of that engine's settings, as for any Veda stack ([Veda](veda.md#vedaengine)). No other stack is affected.                                                                                                                                                                                                                                                                                                                              |
| Administrator                 | Unchanged in power. One publication now reaches every stack.                                                                                                                                                                                                                                                                                                                                                                                   |

Each stack picks its own EarnShare transfer policy; a vault-level rule is not inherited. Registration
must never be opened to everyone, for that reason and for the share-lock exposure above. The
BoringVault's deposit cap is shared by all its stacks; each EarnVault's `maxManagedAssets` is the
per-stack limit.

## Tests

Foundry, under [`test/earn/engines/veda/shared/`](../../../test/earn/engines/veda/shared/), over
stand-ins for a finalized Veda vault whose every gated function asks its own authority
([`VedaAuthMocks.sol`](../../../test/earn/helpers/VedaAuthMocks.sol)); they prove nothing about a Veda
release. The stand-ins model no transfer hook, share lock, pause, or Queue maturity, and give one
account both the RolesAuthority's ownership and the role that repoints each module's authority.

- `VedaLockstepEngine*.t.sol`: the `VedaEngine` accounting, async, fee-freshness and claim-ledger
  invariant suites run against the lockstep engine, and `VedaLockstepEnginePeriphery.t.sol` covers
  publications, Queue changes, and Tellers, Queues and Accountants that misbehave.
- `VedaVaultRegistry.t.sol`: who administers a vault and every publication check.
- `VedaStackFactory.t.sol`: every case runs once per authorization variant, including end-to-end
  deposits, immediate exits and solved queued exits through a real EarnVault.
- `VedaRoleGranter.t.sol`: the granter's authority surface and pre-grant checks, and a stateful
  invariant that only factory-built contracts ever hold an Earn role and nothing else in the role
  table changes.
- `VedaAuthorityOverlay.t.sol`: pass-through of the RolesAuthority, the five added calls, denial
  without reverting when the registry is broken, and that nothing writes to the RolesAuthority.

[`test/earn/gas/VedaStackGas.t.sol`](../../../test/earn/gas/VedaStackGas.t.sol) records stack-building gas
in the [gas baseline](../../development/README.md#gas-baseline); run it under the `spend` profile for
Tempo's pricing, as its header shows.
