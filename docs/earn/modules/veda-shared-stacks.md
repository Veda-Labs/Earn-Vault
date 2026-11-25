# Veda shared-vault stacks

This page owns the contracts that build many Earn stacks on one BoringVault without a transaction
from the vault's administrator for each stack: `VedaVaultRegistry`, `VedaStackFactory` with its two
deployers, `VedaRoleGranter`, which admits what the factory builds, and `VedaForwarderSteward` for
the forwarding solvers' solver list. Every stack runs the released `VedaEngine` and
`VedaForwardingSolver`, unmodified. Valuation, immediate and queued exits, request data, periphery
rotation and stale reports are the [Veda engine](veda.md)'s and are not repeated here.

None of the contracts on this page is audited ([audits](../audit/README.md#scope)). The engine and
the forwarding solver they deploy are the audited ones. The profile lifecycle (`pnpm earn`) neither
deploys nor inspects a stack built here: its Veda inspection requires an engine's registry to name
that one engine, and a `VedaVaultRegistry` [names its caller](#vault-registry).

## What changes

A `VedaEngine` stack needs the vault's administrator twice: the BoringVault's owner deploys, publishes
and binds a `VedaPeripheryRegistry` for that one engine, and the RolesAuthority's owner gives the
engine its role. Here the administrator acts once per vault. It publishes the vault's modules in one
registry that every engine is built on, and empowers one factory. After that an operator builds each
stack, and the factory has the vault admit only what it built.

Nothing else about a stack changes. Its engine caches the Teller, Queue and Accountant published
when it is built, and its owner activates a later publication with `syncVedaPeriphery`, exactly as in
[periphery rotation](veda.md#periphery-rotation).

| Contract                                                                                                             | Count     | Purpose                                                                     |
| -------------------------------------------------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------------- |
| [`VedaVaultRegistry`](../../../src/earn/engines/veda/shared/VedaVaultRegistry.sol)                                   | Per vault | The vault's Teller, optional Queue with its stock solver, and Accountant    |
| [`VedaStackFactory`](../../../src/earn/engines/veda/shared/VedaStackFactory.sol)                                     | Per vault | Operator-gated: builds, binds, authorizes and records a stack               |
| [`VedaEngineDeployer`, `VedaForwardingSolverDeployer`](../../../src/earn/engines/veda/shared/VedaStackDeployers.sol) | Per chain | Hold the engine's and the forwarding solver's creation code for the factory |
| [`VedaRoleGranter`](../../../src/earn/engines/veda/shared/VedaRoleGranter.sol)                                       | Per vault | Grants and revokes two Earn roles                                           |
| [`VedaForwarderSteward`](../../../src/earn/engines/veda/shared/VedaForwarderSteward.sol)                             | Per vault | Owns the forwarding solvers and approves the vault's solvers on each        |

**The vault's administrator** is the BoringVault's owner, or the owner of the BoringVault's current
authority. Both can already take custody of the vault, so naming them adds no trust root. Both are
read live (`isVaultAdmin`): the administrator follows an ownership transfer and a replaced
RolesAuthority, a role never satisfies it, and the zero address never does. On a finalized vault,
whose owner is zero, the administrator is the timelock that owns the RolesAuthority.

## Vault registry

The registry is ownerless and immutable to one BoringVault and base asset. Only the administrator
calls `publish(teller, queue, accountant, solver)`. A Queue and its stock solver are published
together, or both are zero for an immediate-only vault. It exposes what a `VedaEngine` reads from its
periphery registry (`vault`, `baseAsset`, `teller`, `queue`, `accountant`, `version`, `engine`), plus
the stock solver and `isVaultAdmin`.

**A publication changes no engine.** New stacks are built on it, and each existing engine keeps the
tuple it cached until its owner pauses its EarnVault's deposits and calls
`syncVedaPeriphery(minRate, maxRate)`, where the engine checks the wiring, the report's age and the
safe rate against the owner's bounds. A replaced Teller, Queue and stock solver therefore stay live
until every engine has moved and every request on the old Queue is closed
([publications](#publications)).

Publication refuses a tuple unless:

- every module has code, the Teller and a nonzero Queue report this BoringVault and the new
  Accountant, the Accountant reports this BoringVault and the base asset, and the stock solver is
  none of those contracts;
- a nonzero Queue has onchain tracking enabled;
- if the Queue exposes a nonzero `teller()` pointer, it names the published Teller;
- the Teller is the vault's owner or its authority allows it `enter` and `exit`, which an engine does
  not check before it activates a tuple.

These checks do not show that a module's code is benign, that the stock solver holds its Veda
permissions, or that separate account admission accepts each Engine.

**It binds no engine.** A `VedaEngine` binds its EarnVault only when its registry's `engine()` is the
engine itself, which is how a `VedaPeripheryRegistry` lets the vault's owner pick its one engine.
`VedaVaultRegistry.engine()` returns the caller, so the check passes for every engine built on it and
selects none. Which engines the vault serves is decided where the permissions are: by the
[role granter](#role-granter), for the engines a named factory built. An engine anyone else deploys on
the registry holds no Earn role. Read off-chain, `engine()` returns the
address the call was made from and says nothing.

## Stack factory

`VedaStackFactory` is immutable to one registry, the vault's [role granter](#role-granter), the
canonical `EarnFactory`, the two deployers, and the owner and treasury of every forwarding solver it
builds. `EarnFactory`, both deployers and, when the forwarders' owner is a
[steward](#forwarder-steward), that steward are pinned by address and by the code hash named at
construction.

`createStack(jobId, engineParams, core, newTransferPolicyAdmin)`, callable only by the operator:

1. deploys a `VedaEngine` on the registry through the pinned deployer, owned by the factory;
2. calls `EarnFactory.deploy(core)` with that engine, creating the EarnVault, EarnShare and EarnFees
   ([contract reference](../reference/contracts.md#earnfactory));
3. when the vault publishes a Queue, deploys a `VedaForwardingSolver` for this engine against the
   published Queue, Teller and stock solver, has a [steward](#forwarder-steward) approve the vault's
   solvers on it, and authorizes it on the engine;
4. calls `initializeEarnVault(earnVault, core.owner)`, binding the engine to the EarnVault the
   canonical factory just produced and handing it to the stack's owner in the same call;
5. has the granter grant the engine and forwarding solver roles, then checks each role's calls
   against the relevant module authority (`NotAuthorizedOnVeda`); and
6. records the stack (`stack(engine)`) and emits `StackCreated`.

`jobId` is the caller's own nonzero id for the build. It builds one engine: a second `createStack`
or `deployEngine` under the same id reverts (`JobAlreadyBuilt`), whatever its other arguments, and
`engineOf(jobId)` says which engine the first one built, so a build that is sent twice lands once and
a caller can tell whether its build landed. A build that reverted leaves its id free. The id commits
to no settings and is the operator's to use, so a caller told its job was already built reads that
engine's settings and stack owner before adopting it. `discardEngine(engine)`, a pauser's, sets a
pending engine aside for good, for one deployed by an operator key that is no longer trusted.

`core` is the canonical `EarnFactory.DeployParams` with `engine` left zero. `core.owner` becomes the
EarnVault's operator and the engine's owner. `core.transferPolicyId` is attached as given, with zero
meaning unrestricted; a nonzero `newTransferPolicyAdmin` instead creates a TIP-403 whitelist
administered by that address and attaches it. A protected stack is unusable until its policy's
administrator authorizes the [required members](access.md#required-members).
The factory passes `core.controls.migrationMode` through to `EarnFactory`: select
`OperatorEnabled` at deployment if the EarnVault may later move its whole pool to another Engine.
That choice cannot change afterward. For a production vault, set `core.owner` to its governance
timelock if migration must require an admin transaction.

**The operator chooses `core.owner` unless the administrator fixes it.**
`setRequiredStackOwner(owner)` makes `createStack` and `finalizeStack` refuse any other `core.owner`,
and `finalizeMigrationEngine` refuse a target whose operator is anyone else (`StackOwnerNotAllowed`);
zero, the default, leaves the choice to the operator. The rule applies when an engine is given its
role and never afterwards:

- changing or lifting it touches no stack already built;
- a stack's owner can still [hand the stack on](#handing-a-stack-to-another-owner) later, and the
  factory has no say in that; and
- a stack that was handed on migrates through this factory only while the administrator has pointed
  the rule at its new owner.

**The rule fixes who administers a stack, not what a stack admits.** The fees, controls, rate age
bound and transfer policy stay the operator's choice. An engine's deposits and exits skip the Teller's
share lock, so a stack with no fees and an open transfer policy lets any depositor enter before a rate
update and leave after it, at the other holders' expense, whoever owns it. A leaked operator key can
still build such a stack for the required owner. Bounding that needs each stack's settings reviewed
or approved off this contract, and a pause when the key is in doubt.

The factory builds nothing, not even a pending engine, until the administrator names it on the
granter (`AuthorizerNotBound`). It
authorizes only contracts it built itself. Checking an engine's code would not be enough, because a
canonical engine lets its owner bind any EarnVault: the factory owns each engine from construction
until it binds it, and refuses any engine it did not deploy in its own call (`EngineNotPending`),
including one made through the public deployer with the factory named as owner.

**One call or two.** `deployEngine` followed by `finalizeStack` builds the same stack in two
transactions; in between, the engine is owned by the factory, bound to nothing and authorized for
nothing. `finalizeStack` accepts a pending engine once, so it needs no job id. An engine fixes its
modules when it is deployed, so `finalizeStack` refuses one the vault has published past
(`EnginePeripheryStale`); deploy another under a new job id. Under Tempo's T8 pricing, with the
fixture TIP-20 factory and Veda modules, against the 30M per-transaction cap:

| Build                               | Teller that gates callers | Teller with separate account admission and a steward |
| ----------------------------------- | ------------------------- | ---------------------------------------------------- |
| `createStack`, vault with a Queue   | 30.3M                     | 30.5M                                                |
| `createStack`, immediate-only vault | 24.5M                     | 24.5M                                                |
| `deployEngine`                      | 14.7M                     | 14.7M                                                |
| `finalizeStack`, vault with a Queue | 15.7M                     | 16.0M                                                |

On Tempo a vault with a Queue needs the two-call path: one call is over the cap. The figures come
from fixtures, not the live precompiles. The steward column has one listed solver; each further
solver adds a storage write to every forwarder built.
`EarnFactory` is open to anyone, so someone who sees a pending `finalizeStack` can create the same
core first and make it revert; finalize again under another `deploymentId`. Such a core is bound to
nothing and holds nothing.

| Caller             | Functions                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Operator           | `createStack`, `deployEngine`, `deployMigrationEngine`, `finalizeStack`, `deployForwarder`                                                             |
| EarnVault operator | `finalizeMigrationEngine` for an Engine committed to that EarnVault                                                                                    |
| Pausers            | `revokeEngine`, `revokeForwarder`, `pauseRegistrations`, `discardEngine`                                                                               |
| Administrator      | The pausers' functions, `reinstateEngine`, `reinstateForwarder`, `resumeRegistrations`, `setClosedToNewStacks`, `setRequiredStackOwner`, `setOperator` |

Pausers are the accounts the BoringVault's authority allows to call that function on the factory;
the administrator grants those capabilities to the vault's pause roles. Pausing and revoking only
reduce what the factory and its stacks can do. A paused factory refuses every operator call and
every migration candidate finalization.

Pausing is for incidents. A factory that should only stop taking new stacks is closed by the
administrator with `setClosedToNewStacks(true)`: it then deploys no engine and finalizes no new stack,
an engine left pending included (`FactoryClosedToNewStacks`), and `deployForwarder` still works, so
its existing stacks can follow a change of Queue, stock solver or Teller. A closed factory also
refuses `deployMigrationEngine`, and still lets an EarnVault's operator call `finalizeMigrationEngine`
for a candidate deployed before it closed; a pauser stops that candidate with `discardEngine`. Closing
changes nothing else, and a closed factory can still be paused.

The records say what the factory last did, not what the module authorities permit now.
`isEngineReady(engine)` checks the active factory record and the Engine's authority on its current
Teller and Queue. `canEngineUseTeller(engine)` checks whether either bulk call remains authorized,
regardless of the factory record. `isForwarderReady(forwarder, solver)` checks the queued path's
wiring, the Engine's forwarder authorization, the forwarder's approved solver and its authority to
call the stock solver, and the stock solver's own part of a settlement: its authority to call
`solveOnChainWithdraws` on the Queue and `bulkWithdraw` on the Teller, and the Queue's authority to
call `boringSolve` back on it. These views do not check Teller account admission, pauses, caps, liquidity,
transfer policy, Queue maturity or a request deadline. A public module capability also reads as
authorized; the deployment policy must check whether a role is actually required.
`stack(engine).forwarder` is the forwarding solver built with the stack, and a later
`deployForwarder` does not change it; `ForwarderDeployed` lists every forwarder, and the engine's
`authorizedForwarder` says which ones its owner admitted.

The views also do not check that the Teller can still mint and burn on the BoringVault, which the
registry checks once at publication, or that the stock solver is the one its Queue expects.
`canEngineUseTeller` reads the Teller only: after a revocation, check the Engine's Queue request and
cancellation permissions separately where another role or a public capability could grant them.

## Role granter

A Veda module asks its authority whether a caller may call a function, and a RolesAuthority gates by
function, not by argument: whoever may call `setUserRole` may give any role to anyone.
`VedaRoleGranter` narrows that in code. The administrator points the RolesAuthority's own `authority`
at the granter, whose `canCall` admits one triple: the granter, calling `setUserRole`, on that
RolesAuthority. The owner keeps every power, no role number is spent on a registrar, and no
capability row that targets the RolesAuthority becomes live, because the RolesAuthority does not
consult its own role table for calls on itself.

The granter's RolesAuthority, registry, vault and two role numbers are immutable. Its only writes to
the RolesAuthority are `setUserRole` for those two roles. It accepts only the factories the RolesAuthority's owner names
(`setFactory(factory, true)`), and names one only if it reports this granter and this granter's
registry as its own. An engine takes its modules from its registry, so a factory that builds on some
other registry must never receive the vault's roles; this check stops one from being named by
mistake. It is a check of wiring, not of code: the administrator still reviews the factory it names.
Several factories can be named at once ([replacing the factory](#replacing-the-factory)).

Before a grant the granter also requires that:

- it is still the RolesAuthority's authority, so the owner and the granter are the only paths to the
  role table;
- the RolesAuthority still has an owner, who could cut it off;
- the BoringVault answers to that RolesAuthority; and
- the role has no capability on the BoringVault's `manage`, `enter`, `exit`,
  `setBeforeTransferHook`, `setAuthority` or `transferOwnership`, nor on the RolesAuthority's
  `setUserRole`, `setRoleCapability`, `setPublicCapability`, `setAuthority` or `transferOwnership`.

Revocation skips those checks so that it works whenever the RolesAuthority admits it.

Review both role numbers' holders and capabilities before setup. The Engine role may reuse an
existing role, such as role 12 on the current Tempo vaults, if its existing capabilities and holders
are intentional. A RolesAuthority cannot list a role's holders, so no contract here can check this:

- an account that already holds either number gains the Earn capabilities the moment the setup batch
  adds them: lock-free deposits and exits on the Teller for the engine role, and solving any matured
  request on the Queue through the stock solver for the forwarder role. Read the RolesAuthority's
  `UserRoleUpdated` history for both numbers; and
- a number that already carries a capability elsewhere (a manager, an Accountant) gives it to every
  engine or forwarding solver. Only the custody and role-administration functions above are checked.

Pointing the RolesAuthority's `authority` elsewhere stops new grants and the granter's role
revocations. Roles already granted stay until the owner clears them or removes the roles'
capabilities, so pause and revoke through the factory first.

### Teller account admission is separate

The granter grants roles whether or not a Teller also checks account membership. The factory does
not read or change that membership. On a Teller with an enforced list, a separate administrator or
service must admit each Engine before its deposits and exits work. A Queue that checks the request
owner and a stock solver that withdraws through the Teller may also need membership. The planned
setup for the three current Tempo vaults uses roles and no Teller account list. A future listed
setup needs its own admission and revocation procedure before the service reports a customer stack
ready for use.

## Forwarder steward

A `VedaForwardingSolver` lets only its owner approve the solvers that may trigger it, and its
ownership moves in two steps, so a factory cannot approve one and hand the forwarder on in the same
call. Without a steward a new forwarding solver settles nothing until its owner sends a transaction.

`VedaForwarderSteward` is the forwarders' owner from construction. A factory built with
`forwarderOwnerIsSteward` requires the steward's code hash to be the one its deployer names
(`forwarderStewardCodeHash`), which a reviewer compares with the release: a contract that only
answered `seed` would leave every forwarder with no approved solver and an owner that could never
approve one. Its own owner, typically a Safe,
keeps one list of solvers (`setSolver`, at most eight). Applying the list to a forwarder is open to
anyone, because it only moves that forwarder toward the list:

- `seed(forwarder)` approves every listed solver. A factory built with `forwarderOwnerIsSteward`
  calls it on each forwarder it builds, with a stack and through `deployForwarder`, and refuses to
  build a forwarder while the list is empty (`ForwarderNotSeeded`).
- `prune(forwarder, accounts)` removes the named accounts that are approved there and not listed. A
  retired solver stays approved on a forwarder until it is pruned there.

A solver can trigger a settlement and nothing else: the forwarder pays each request's owner through
its engine and keeps any surplus for its treasury. The steward's owner keeps the forwarders' other
owner functions through `setForwarderTreasury`, `rescue`, `releaseForwarder` and `acceptForwarder`,
and cannot renounce its ownership. The steward cannot move tokens it holds, so it is never a
forwarder's treasury. It keeps no list of forwarders: applying a change to all of them means naming
each one from the factory's `ForwarderDeployed` events.

## Setup

Deploy the registry, role granter, factory and optional forwarder steward, then review their code,
addresses, role IDs, and pinned code hashes. Check the existing RolesAuthority authority before
replacing it. In one vault administrator batch:

1. Publish the live Teller, optional Queue and stock solver, and Accountant in the registry.
2. Give the Engine role the Teller's `bulkDeposit` and `bulkWithdraw` capabilities. If the vault has a
   Queue, grant its request and tracked-cancel capabilities to that role.
3. If the vault has a Queue, give the forwarder role `boringRedeemSolve` on the stock solver. After
   a forwarder receives that role, the factory checks that the stock solver's authority admits the
   call.
4. Set the RolesAuthority's external authority to the granter and name the factory.
5. Give the vault's pause roles the factory's revoke, pause and discard functions.
6. If every stack on the vault is to have one owner, call `factory.setRequiredStackOwner(owner)`.
   Without it the operator key chooses each stack's owner.
7. Call `granter.assertSetup(registry, factory)` to check the role-grant wiring and protected
   capabilities before the batch completes.

For a role-only Teller, confirm both bulk functions are not public in the deployment preflight. A
Teller with separate account admission needs its own setup and customer admission process. Neither
`assertSetup` nor the factory verifies account membership.

## Operations

### Publications

Every publication is the administrator's. It moves no stack: each Engine's owner activates it. Give
new modules their own Veda permissions and the Earn roles' exact capabilities, then publish the
new tuple. End the batch with `granter.assertSetup(registry, factory)`. If a Teller has separate
account admission, arrange that policy before activating customer stacks; the registry does not
inspect membership. It still rejects a Queue whose exposed nonzero `teller()` pointer names a
different Teller.

After a change of Queue, stock solver or Teller, the operator calls `deployForwarder(engine)`. The
stack owner then pauses deposits, authorizes the new forwarder, calls `syncVedaPeriphery` with tight
rate bounds, checks the stack, and resumes deposits. Keep old modules and permissions live until
all Engines have moved and all requests on the old Queue are closed. The factory builds forwarders
only for the tuple currently published.

### Incidents

- If the operator key leaks, call `pauseRegistrations`, revoke the stacks and prepared migration
  candidates built by that key, discard every pending engine (`engineAt`, `stack(engine).status`),
  and have the administrator replace the operator before resuming. Replacing the operator also
  retires its migration candidates: one deployed by a former operator is never finalized
  (`CandidateOperatorReplaced`).
- To stop one stack, call `revokeEngine`, and revoke any migration candidate already prepared for
  it. A revoked stack gets no new candidate, and a pending one is not finalized for it
  (`EngineNotActive`), until the administrator reinstates it. The granter removes its role. On a role-gated Teller this
  stops deposits and immediate exits, and may stop queued requests and cancellations. If a bulk
  function is public, role removal alone does not stop it. Check `canEngineUseTeller(engine)` after
  revocation. A separate account-admission policy needs a separate removal action.
- To stop deposits but keep exits, the stack owner pauses EarnVault deposits. The vault-side
  `revokeEngine` is not a deposit-only control.
- To stop the whole vault, pause the Teller.

### Moving an existing stack onto the vault

The destination vault's factory can prepare a replacement Engine for an existing EarnVault without
deploying another EarnVault, EarnShare or EarnFees:

1. The factory operator calls `deployMigrationEngine(jobId, engineParams, existingEarnVault)`.
   The Engine is committed to that EarnVault, factory-owned, unbound and unauthorized. An ordinary
   `deployEngine` cannot use the migration path, and this candidate cannot become a fresh stack.
2. The **current `EarnVault.operator()`** calls `finalizeMigrationEngine(engine)`. The factory checks
   the target's `OperatorEnabled` mode, base asset, live source-Engine binding, and current registry
   version. It also requires that the operator who deployed the candidate is still the factory's
   operator, that the caller is the [required stack owner](#stack-factory) when one is set, and that
   the source Engine is not one this factory has revoked. It binds the candidate, transfers Engine ownership to that operator, grants its Engine
   role, and builds and authorizes a Queue forwarder when needed. This call moves no funds.
3. The same EarnVault operator later calls
   [`migrateEngine(newEngine, minNewEngineShares, minAssetsRetained)`](../architecture/system.md#whole-pool-engine-migration)
   with reviewed floors.

**Finalize and migrate in one batch, or check the owner in the migration batch.** A candidate goes
to the operator who finalizes it, an EarnVault's operator can change afterwards, and `migrateEngine`
does not look at the Engine's owner. A new operator who migrated into a candidate the former operator
finalized would leave the pool in an Engine the former operator still administers: its forwarder
list, periphery activation, rate age bound, settlement recovery and dust sweep, never the BoringVault
shares that back the pool. One execution batch that calls `finalizeMigrationEngine` and then
`migrateEngine` has no such gap. When they are separate transactions, the migration batch calls
`factory.assertMigrationCurrent(engine)` immediately before `migrateEngine`; it reverts unless the
factory has not revoked the candidate, the candidate is still allowed on its Teller and Queue, and
its owner is the EarnVault's current operator (`MigrationOwnerStale`). For a stale candidate, a
pauser revokes it and the new operator prepares another. The check compares the two seats and
nothing else a former operator may have set on the Engine, such as its forwarder list, so a new
operator prepares its own candidate instead of accepting ownership of one someone else finalized.

The destination vault must have named its factory on the role granter during one-time setup. No
per-migration destination vault admin role grant is needed after that. A prepared candidate's
`stack(engine).status` is `Active` because it has roles, even while `EarnVault.engine()` still names
the source Engine. Its `earnShare` and `earnFees` record fields remain zero. If the Queue is used,
verify the forwarder's approved worker and live solver path; a role grant alone does not make the
worker ready.

`migrateEngine` needs zero open Earn async requests, a full immediate source-Teller redemption,
and a successful destination deposit. The factory does not supply liquidity or migrate assets.
After migration, revoke the old Engine's role through its source vault's factory or administrator.
Discard unused pending candidates and revoke prepared candidates that will not be used. A Teller
with separate account admission still needs that admission before the Engine can operate.

The target and reciprocal source-Engine checks guard against mistakes. They do not prove that the
existing EarnVault came from the pinned `EarnFactory`, or that the target is an EarnVault at all: any
contract that answers those reads passes, and the Engine is then bound to it. That factory has no
onchain registry of its deployments, and anyone can deploy a genuine EarnVault through it, so a
provenance check would not decide who may hold a role either. What bounds a candidate is what bounds
a fresh stack: the operator that deployed it, and the required stack owner. Without a required
owner, the operator key can prepare an authorized Engine for an owner and a contract of its
choosing. Funded contract tests exercise both same-vault and distinct-vault migration with mocks.
Production use still needs a funded two-vault fork rehearsal with the real source buffer,
destination cap, rates, roles, and migration floors.

### Handing a stack to another owner

A stack has two seats, and the released contracts move them separately: the EarnVault's operator
(`transferOperator`, then `acceptOperator`) and the Engine's owner (`transferOwnership`, then
`acceptOwnership`). Move both in the same batches. A stack whose EarnVault has a new operator and
whose Engine still has the old owner leaves the old owner administering the Engine. Neither call
involves the factory, so `requiredStackOwner` neither blocks a transfer nor follows one, and the
stack's record, role and factory-built forwarders are unchanged. Its forwarders stay owned by the
factory's forwarder owner. While a required owner is set, a stack that was handed on gets a
replacement Engine from this factory only if the administrator points `requiredStackOwner` at its
new owner until the candidate is finalized, then sets it back.

### Replacing the factory

A new release uses a new factory against the same registry and granter. The administrator names it
beside the old one and, in the same batch, closes the old one to new stacks
(`setClosedToNewStacks(true)`). Keep the old factory named while its stacks need factory-mediated
revocation, reinstatement or new forwarding solvers. Do not leave it paused: only the factory that
built a stack can build its forwarders, and a paused factory builds none. Once the administrator stops
naming a factory, its existing roles remain and only the RolesAuthority owner can revoke them
directly. The factory's own records do not change.

## Trust and failure modes

None of these contracts is the vault's owner or can reach `manage`, `enter`, `exit`, `setAuthority`
or `transferOwnership` on it.

| If this fails                 | Worst case                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Operator key leaks            | Stacks with an owner, fees, controls, rate age bound and transfer policy of the attacker's choice. Their deposits and exits skip the Teller's share lock, so their owner can enter before a rate update and leave after it, which dilutes every holder of the BoringVault. Also forwarding solvers for existing stacks, which settle nothing until an engine's owner admits them. No role, no registry, no other stack's settings, no custody. |
| Factory has a bug             | A role for an address that is not a genuine engine or forwarding solver: the same access as above, and for a forwarder, solving requests on the vault's Queue                                                                                                                                                                                                                                                                                  |
| Role granter has a bug        | Any role to anyone, which is custody of the vault. Nothing bounds it but its code.                                                                                                                                                                                                                                                                                                                                                             |
| Forwarder steward's owner     | The solvers on every forwarder it owns, their treasuries and their surplus. A solver it approves can trigger settlement, which pays request owners through their engines. No custody of the vault.                                                                                                                                                                                                                                             |
| A solver key leaks or is lost | Leaked: settlements at a time of the holder's choosing, paid as recorded. Lost: queued exits wait, and can pass their deadline, until the steward's owner lists another solver and each forwarder is seeded.                                                                                                                                                                                                                                   |
| Pauser is compromised         | Every stack revoked and registrations paused until the administrator restores them. No funds move.                                                                                                                                                                                                                                                                                                                                             |
| A stack's owner               | Malicious: misuse of that engine's settings, as for any Veda stack ([Veda](veda.md#vedaengine)). Unresponsive: its stack stays on replaced modules after a publication. No other stack is affected.                                                                                                                                                                                                                                            |
| Administrator                 | Unchanged in power. One publication is offered to every stack, and each stack's owner activates it.                                                                                                                                                                                                                                                                                                                                            |

Each stack picks its own EarnShare transfer policy; a vault-level rule is not inherited. Registration
must never be opened to everyone, for that reason and for the share-lock exposure above. The
BoringVault's deposit cap is shared by all its stacks; each EarnVault's `maxManagedAssets` is the
per-stack limit.

## Tests

The Foundry tests use stand-ins for a finalized Veda vault, with the released `VedaEngine` and
`VedaForwardingSolver`. They do not prove behavior on a deployed Veda release. The shared suites
cover registry publication, factory-built stacks, role-granter bounds, forwarder seeding, and
end-to-end role-gated deposits and exits. `VedaRoleGranterAdmission.t.sol` checks the separation:
a factory-built Engine receives its role while still absent from a Teller list; a separate
administrator lists it before deposits work; revocation removes the role without changing the list;
and a Teller rotation does not require the shared contracts to manage membership.

[`test/earn/gas/VedaStackGas.t.sol`](../../../test/earn/gas/VedaStackGas.t.sol) records stack-building gas
in the [gas baseline](../../development/README.md#gas-baseline); run it under the `spend` profile for
Tempo's pricing, as its header shows.
