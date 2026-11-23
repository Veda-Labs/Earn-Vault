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
| [`VedaRoleGranter`](../../../src/earn/engines/veda/shared/VedaRoleGranter.sol)                                       | Per vault | Grants the two Earn roles and, for a Teller that admits by account, lists   |
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
- the Teller is the vault's owner or its authority allows it `enter` and `exit`, which an engine does
  not check before it activates a tuple; and
- where the Teller keeps an [account allowlist](#teller-allowlist), a Queue that applies one applies
  this Teller's, and the list admits the stock solver, because the solver redeems every settled
  request through the Teller. A list that is not enforced admits every account;
  [`assertSetup`](#setup) is what requires the solver to be on an enforced one.

These checks do not show that a module's code is benign, that the stock solver holds its Veda
permissions, or that the Earn stacks are admitted to the new modules.

**It binds no engine.** A `VedaEngine` binds its EarnVault only when its registry's `engine()` is the
engine itself, which is how a `VedaPeripheryRegistry` lets the vault's owner pick its one engine.
`VedaVaultRegistry.engine()` returns the caller, so the check passes for every engine built on it and
selects none. Which engines the vault serves is decided where the permissions are: by the
[role granter](#role-granter), for the engines a named factory built. An engine anyone else deploys on
the registry holds no role and no place on a Teller's list. Read off-chain, `engine()` returns the
address the call was made from and says nothing.

## Stack factory

`VedaStackFactory` is immutable to one registry, the vault's [role granter](#role-granter), the
canonical `EarnFactory`, the two deployers, and the owner and treasury of every forwarding solver it
builds. `EarnFactory` and both deployers are pinned by address and by the code hash named at
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
5. has the granter admit the engine and the forwarding solver, then requires that each is actually
   allowed its calls by the module's own authority and that a Teller with an account allowlist
   admits the engine (`NotAuthorizedOnVeda`, `NotListedOnTeller`); and
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

| Build                               | Teller that gates callers | Teller with a list, and a steward |
| ----------------------------------- | ------------------------- | --------------------------------- |
| `createStack`, vault with a Queue   | 30.3M                     | 31.1M                             |
| `createStack`, immediate-only vault | 24.5M                     | 25.0M                             |
| `deployEngine`                      | 14.7M                     | 14.7M                             |
| `finalizeStack`, vault with a Queue | 15.7M                     | 16.5M                             |

On Tempo a vault with a Queue needs the two-call path: one call is over the cap. The figures come
from fixtures, not the live precompiles. The steward column has one listed solver; each further
solver adds a storage write to every forwarder built.
`EarnFactory` is open to anyone, so someone who sees a pending `finalizeStack` can create the same
core first and make it revert; finalize again under another `deploymentId`. Such a core is bound to
nothing and holds nothing.

| Caller        | Functions                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------- |
| Operator      | `createStack`, `deployEngine`, `finalizeStack`, `deployForwarder`                                     |
| Pausers       | `revokeEngine`, `revokeForwarder`, `pauseRegistrations`, `discardEngine`                              |
| Administrator | The pausers' functions, `reinstateEngine`, `reinstateForwarder`, `resumeRegistrations`, `setOperator` |

Pausers are the accounts the BoringVault's authority allows to call that function on the factory;
the administrator grants those capabilities to the vault's pause roles. Pausing and revoking only
reduce what the factory and its stacks can do. A paused factory refuses every operator call.

The records say what the factory last did, not what is permitted now: the administrator can change a
permission or the Teller's list directly, and a function the vault lets anyone call stays callable by
a revoked engine unless the Teller's list is what admits it. `isEngineReady(engine)` reads live the
Teller and Queue the engine itself uses, which are the published ones only once its owner has
activated them: an active stack whose engine they allow its calls and, where the Teller keeps a
list, admit. It does not cover a paused Teller, a deposit cap or the stack's own controls.
`canEngineUseTeller(engine)` is the check after a revocation: whether the engine's Teller would
still take a deposit from it or pay it an immediate exit, whatever the factory's record says.
`isForwarderReady(forwarder, solver)` reads the wiring and permissions of the queued path, which
may go unused for a long time: the forwarder is active, fixed to the Queue and Teller its engine
uses now and, once the engine is on the published tuple, to the published stock solver, admitted by
its engine, allowed on its stock solver, and has `solver` approved, and a Teller with a list admits
the stock solver and, where the Queue applies that list, the engine. True does not mean a settlement
would succeed: it covers no pause, liquidity, deficit, transfer policy, maturity or deadline, nor the
stock solver's own permissions.
`stack(engine).forwarder` is the forwarding solver built with the stack, and a later
`deployForwarder` does not change it; `ForwarderDeployed` lists every forwarder, and the engine's
`authorizedForwarder` says which ones its owner admitted.

## Role granter

A Veda module asks its authority whether a caller may call a function, and a RolesAuthority gates by
function, not by argument: whoever may call `setUserRole` may give any role to anyone.
`VedaRoleGranter` narrows that in code. The administrator points the RolesAuthority's own `authority`
at the granter, whose `canCall` admits one triple: the granter, calling `setUserRole`, on that
RolesAuthority. The owner keeps every power, no role number is spent on a registrar, and no
capability row that targets the RolesAuthority becomes live, because the RolesAuthority does not
consult its own role table for calls on itself.

The granter's RolesAuthority, registry, vault and two role numbers are immutable. Its only writes are
`setUserRole` for those two roles and, [where the Teller keeps a list](#teller-allowlist),
`setAllowedAccounts` for engines. It accepts only the factories the RolesAuthority's owner names
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

Choose two role numbers nothing else uses, and confirm it before the setup batch. A RolesAuthority
cannot list a role's holders, so no contract here can check this:

- an account that already holds either number gains the Earn capabilities the moment the setup batch
  adds them: lock-free deposits and exits on the Teller for the engine role, and solving any matured
  request on the Queue through the stock solver for the forwarder role. Read the RolesAuthority's
  `UserRoleUpdated` history for both numbers; and
- a number that already carries a capability elsewhere (a manager, an Accountant) gives it to every
  engine or forwarding solver. Only the custody and role-administration functions above are checked.

Pointing the RolesAuthority's `authority` elsewhere stops new grants, `relist` and the granter's role
revocations alike. Roles already granted stay until the owner clears them or removes the roles'
capabilities, so pause and revoke through the factory first. The granter keeps its permission on the
Teller until the owner takes that away too, and a revocation still delists through it.

### Teller allowlist

One granter serves both kinds of Teller. A Teller either gates its callers, and then the engine
role's capabilities are what admit an engine, or it also checks the account whose position changes,
whoever calls: a deposit needs its share recipient on the Teller's list and a withdrawal its share
owner, each while that direction is enforced, and a Queue bound to the Teller (`queue.teller()`)
applies the same list to a request's owner when the request is filed and again when it is settled.
On such a vault a role is not enough to use the Teller, and where the vault opens the bulk paths to
every caller a role decides nothing: the list alone admits an engine to the Teller and delisting
alone stops it there.

`tellerAllowlist` says which kind the vault runs. The RolesAuthority's owner sets it with
`setTellerAllowlist(bool)`. It starts clear, for a Teller that gates callers only. While it is set:

- authorizing an engine also lists it on the registry's published Teller, and reverts unless the
  Teller reports it listed;
- revoking an engine also delists it; and
- anyone may call `relist`.

The role is granted either way, since a Queue and a stock solver gate their callers on both kinds of
vault. The owner lets the granter call `setAllowedAccounts` on a Teller that keeps a list, through a
role nothing else holds. That function takes any accounts, so only the granter's code keeps the
permission to Earn engines. `listedOn(engine)` is its record: the Teller it last listed the engine
on, `address(1)` for an engine revoked through its factory, listed or not, until it is authorized
again, and zero for an engine it never listed.

| Function                    | Caller                    | What it writes                                                                |
| --------------------------- | ------------------------- | ----------------------------------------------------------------------------- |
| `setEngineAuthorized`       | A named factory           | The engine role and, with the flag set, the engine's listing, or removes both |
| `setForwarderAuthorized`    | A named factory           | The forwarder role                                                            |
| `setFactory`                | The RolesAuthority owner  | The factories it accepts                                                      |
| `setTellerAllowlist`        | The RolesAuthority owner  | The flag; no list changes                                                     |
| `relist(engines)`           | Anyone, with the flag set | Lists engines that hold the engine role on the Teller published now           |
| `redelist(engines)`         | Anyone                    | Takes revoked engines off the published Teller and the one each engine uses   |
| `assertSetup(reg, factory)` | Anyone (a view)           | Nothing; reverts unless the [setup](#setup) is complete                       |

- **Listing follows the engine role.** `relist` lists a contract that holds the engine role, which a
  named factory or the owner gave it, and skips everything else, so one revoked engine does not fail
  a batch. It reverts unless the granter is still the RolesAuthority's authority, since only then
  does the role say who is an engine. It is how the vault's engines reach a newly published Teller before their owners activate
  it, and how engines authorized before the flag was set reach the list. It skips an engine whose
  latest listing by the granter was on this Teller.
- **Revoking removes the role and each listing independently.** A RolesAuthority that no longer
  admits the granter does not keep an engine listed (`EngineRoleRevocationDeferred`), and a Teller
  that still lists the engine and cannot be written does not keep the role
  (`EngineDelistingDeferred`, which `redelist` finishes). The engine is recorded as revoked whatever
  the flag says, so that nothing here lists it again and `redelist` takes it off a Teller it reaches
  later. The call reverts only when the role could not be cleared and no listing was found.
- **Where it delists.** On the published Teller, which the engine's owner could activate; on the
  Teller the engine reports, which it uses until then; and on the Teller the granter last listed it
  on. An engine can activate only the published Teller, so a listing left on any other Teller is one
  it cannot use. A Teller that does not answer `allowedAccounts` keeps no list and is passed over.
  The granter looks for listings when it listed the engine or the engine holds the engine role,
  whatever the flag says, so it also delists an engine someone else listed; the stock solver and
  any other account are not the granter's to remove.

A forwarding solver holds no shares and is never listed. The stock solver redeems settled requests
through the Teller and must be on the list; the administrator lists it, and publication checks it.

**The record is not the list.** The administrator can change a Teller's list directly, and the
granter does not learn of it. `relist` does not repeat the granter's latest listing, so a direct
delisting on the Teller that listing was made on stays, but the engine is carried to the next Teller
published while it holds the engine role: to keep an engine off, use `revokeEngine`. A direct listing
of an engine the granter revoked is removed by `redelist`; reinstating the engine through its factory
is what lists it again.

**What delisting stops.** An engine's deposits and immediate exits together and, on a Queue bound to
the Teller, its new requests and the settlement of the ones already queued. A request that passes
its deadline while its engine is delisted does not settle afterwards. There is no deposit-only stop
from the vault's side: a stack's own deposit pause is its EarnVault's, and where the vault opens
`bulkDeposit` to every caller, anyone can mint shares to a listed engine. Delisting stops nothing on
a Queue that applies no list, and a Teller that stops enforcing its list admits every account,
whatever the granter recorded. Keep the Teller's routed deposit, which mints to a named recipient
under the share lock, restricted to trusted callers: a deposit to an engine would lock the engine's
shares against a queued request.

**With the flag clear on a Teller that enforces a list**, the factory still refuses to report a stack
whose engine the list does not admit (`NotListedOnTeller`), and `assertSetup` reverts
(`TellerEnforcesList`). With `deployEngine` and `finalizeStack`, whoever keeps the list can list the
engine between the two calls, which makes admission a second key's decision at one transaction per
stack. Before listing, that key confirms `stack(engine).status` is pending in the factory it trusts:
the engine deployer is open to anyone, so an engine's code proves nothing about who built it.
Revoking such an engine still delists it where the granter may write the list; where it may not,
`EngineDelistingDeferred` names the Teller and the key that keeps the list delists it.

## Forwarder steward

A `VedaForwardingSolver` lets only its owner approve the solvers that may trigger it, and its
ownership moves in two steps, so a factory cannot approve one and hand the forwarder on in the same
call. Without a steward a new forwarding solver settles nothing until its owner sends a transaction.

`VedaForwarderSteward` is the forwarders' owner from construction. Its own owner, typically a Safe,
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

Deploy the deployers once per chain. Per vault, anyone deploys the registry, the granter and the
factory; none holds a permission until the administrator's one batch, which a new vault's deployer
runs before handing the vault over. Before that batch, review:

- the verified code of the registry, the granter and the factory, since the onchain checks cover
  their wiring and never their code;
- the factory's `registry`, `authorizer`, `operator`, `forwarderOwner`, `forwarderOwnerIsSteward`,
  `forwarderTreasury` and three pinned code hashes, against the registry being published on and the
  reviewed release;
- the granter's `rolesAuthority`, `registry` and two role numbers, and that
  [nothing else holds or uses those numbers](#role-granter); and
- with a forwarder steward, its verified code, its owner and its list of solvers.

Confirm the RolesAuthority's `authority` is zero, since setting it displaces whatever was there. The
batch:

1. `registry.publish(...)` with the vault's live modules. For a Teller that keeps a list, first list
   the stock solver on it and bind the Queue to it (`queue.setTeller(teller)`).
2. Give the Earn engine role `bulkDeposit` and `bulkWithdraw` on the Teller and, with a Queue,
   `requestOnChainWithdraw` and `cancelOnChainWithdrawUsingRequestId` on it. Where the vault opens a
   function to every caller, the role's capability on it is unused.
3. Give the Earn forwarder role `boringRedeemSolve` on the stock solver.
4. `rolesAuthority.setAuthority(granter)`, then `granter.setFactory(factory, true)`.
5. Give the vault's pause roles the factory's `revokeEngine`, `revokeForwarder`,
   `pauseRegistrations` and `discardEngine`.
6. For a Teller that keeps a list: give a role nothing else holds `setAllowedAccounts` on the
   Teller, give that role to the granter, and call `granter.setTellerAllowlist(true)`.
7. `granter.assertSetup(registry, factory)`, naming the registry published in this batch. It reverts
   the batch unless the granter was built for that registry, the factory is named, every pre-grant
   check passes for both roles, and the flag matches the published Teller:
   - with the flag clear, the Teller does not refuse the granter as an account, as a Teller that
     enforces a list would refuse every engine;
   - with the flag set, the Teller enforces its list in both directions, lets the granter write it
     and does not let an account without a role write it, and a published Queue applies that same
     list with its stock solver on it. It cannot show that no other account holds the role that
     writes the list. The granter itself must not be on the list, which is how it tells an enforced
     list from an idle one.

## Operations

### Publications

Every publication is the administrator's. It moves no stack: each engine's owner activates it. In
the publication batch:

- give the new modules their own Veda permissions, including the stock solver's;
- admit the Earn stacks to them by adding the Earn roles' capabilities on them;
- for a Teller that keeps a list: list the stock solver, bind the Queue, give the granter's role
  `setAllowedAccounts` on it, set the flag if this is the vault's first such Teller, and after
  publishing call `granter.relist(engines)` and `granter.redelist(engines)` with every engine of the
  vault's factories (`engineAt`). An engine whose owner activates a Teller that does not list it has
  its deposits and exits refused until `relist` carries it, so list before any owner is asked to
  activate. Both functions read the granter's record and the role table when they run, so an engine
  revoked while the batch waits is handled correctly. Listing engines on the new Teller directly
  bypasses the record: a revocation still delists an engine that holds the engine role, and
  `redelist` removes one revoked through its factory before the Teller was published; and
- end with `granter.assertSetup(registry, factory)`.

Then, for each stack:

- after a change of Queue, stock solver or Teller, the operator calls `deployForwarder(engine)`. A
  forwarding solver fixes all three at construction;
- the stack's owner pauses deposits, calls `setAuthorizedForwarder` for the new forwarder and
  `syncVedaPeriphery` with bounds tight around the outgoing rate, checks the stack, and resumes
  deposits ([periphery rotation](veda.md#periphery-rotation)). A request filed on a new Queue before
  its forwarder is admitted waits until it is; and
- `isEngineReady` and `isForwarderReady` show the result.

Keep a replaced Teller, Queue and stock solver, the Earn roles' capabilities on them, and the stacks'
old forwarding solvers live until every engine's `peripheryVersion` is the published one and
`openClaimsByQueue(queue)` is zero on every engine. The factory builds a forwarding solver only for
the tuple published now. An owner who does not activate a publication keeps its stack on modules the
administrator wants to retire: the vault's side can stop that stack with `revokeEngine`, and cannot
move it.

### Incidents

- **A leaked operator key.** Call `pauseRegistrations` first: it stops every operator call at once.
  Then revoke the engines that key built, and have the administrator replace the operator
  (`setOperator`) before it resumes registrations.
- **One stack.** `revokeEngine` stops its deposits and immediate exits, and its queued requests and
  cancellations unless the vault lets anyone call those. Its users cannot exit instantly until the
  administrator reinstates it, so a false alarm costs them the administrator's delay. With the
  [flag](#teller-allowlist) set, revoking also delists the engine, which is what stops it on a vault
  that opens the Teller to every caller, and requests it already queued wait until it is reinstated
  or pass their deadline. Watch the granter's `EngineDelistingDeferred` and
  `EngineRoleRevocationDeferred`, and read `canEngineUseTeller(engine)` after every revocation: the
  factory records the engine as revoked either way, and until the named Teller or the role is
  cleared the engine may still work. Finish a deferred delisting with `granter.redelist`; a role the granter could not clear is
  the RolesAuthority owner's to clear. `reinstateEngine` lists an engine on the published Teller, so
  for an engine that has not activated it, the owner activates first or the administrator lists the
  engine on its own Teller directly.
- **A stack that should take no more deposits.** Its owner pauses its EarnVault's deposits. The
  vault's side has no deposit-only stop: `revokeEngine` is its lever.
- **The whole vault.** Pause the Teller as before; these contracts do not change that.

### Moving an existing stack onto the vault

The factory builds an engine only together with a new EarnVault. It has no call that builds one
for an EarnVault that already exists, so a stack that moves here from another BoringVault through
[whole-pool engine migration](../architecture/system.md#whole-pool-engine-migration) is the one
case that still needs the administrator for each stack:

1. the stack's owner deploys a `VedaEngine` on this vault's registry and binds it to the existing
   EarnVault, which the registry allows for any engine;
2. the administrator gives that engine the Earn engine role on the RolesAuthority directly and,
   where the Teller keeps a list, lists it or lets `relist` carry it, since it now holds the role;
   and
3. the EarnVault's operator calls `migrateEngine`.

Such an engine is in no factory's records. Pausers cannot revoke it, the operator cannot build it a
forwarding solver, and the administrator revokes it by hand, the role first and the listing after.

### Replacing the factory

A factory is pinned to exact engine and core code, so a new release means a new factory, deployed
against the same registry and granter and named by the administrator beside the old one. Each
factory reaches only the stacks it built. Keep the old factory named for as long as its stacks
exist: its pausers revoke them, its operator builds their forwarding solvers after a publication,
and the administrator reinstates them, all through it. Pause its registrations so that it builds no
new stacks.

Once the administrator stops naming a factory, that factory can change nothing. Its stacks keep
their roles and listings, are still carried to a new Teller by `relist`, and keep working, but they
cannot get a forwarding solver for a newly published Queue, and only the administrator can revoke
them: with `setUserRole` on the RolesAuthority first, and then `setAllowedAccounts` on the Teller. In
that order, because an engine that still holds the role can be carried back onto a Teller's list by
anyone. Each leaves the factory's own record and the granter's unchanged.

## Trust and failure modes

None of these contracts is the vault's owner or can reach `manage`, `enter`, `exit`, `setAuthority`
or `transferOwnership` on it.

| If this fails                 | Worst case                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Operator key leaks            | Stacks with an owner, fees, controls, rate age bound and transfer policy of the attacker's choice. Their deposits and exits skip the Teller's share lock, so their owner can enter before a rate update and leave after it, which dilutes every holder of the BoringVault. Also forwarding solvers for existing stacks, which settle nothing until an engine's owner admits them. No role, no registry, no other stack's settings, no custody. |
| Factory has a bug             | A role or a listing for an address that is not a genuine engine or forwarding solver: the same access as above, and for a forwarder, solving requests on the vault's Queue                                                                                                                                                                                                                                                                     |
| Role granter has a bug        | Any role to anyone, which is custody of the vault, and any account on or off the Teller's list. Nothing bounds it but its code.                                                                                                                                                                                                                                                                                                                |
| Forwarder steward's owner     | The solvers on every forwarder it owns, their treasuries and their surplus. A solver it approves can trigger settlement, which pays request owners through their engines. No custody of the vault.                                                                                                                                                                                                                                             |
| A solver key leaks or is lost | Leaked: settlements at a time of the holder's choosing, paid as recorded. Lost: queued exits wait, and can pass their deadline, until the steward's owner lists another solver and each forwarder is seeded.                                                                                                                                                                                                                                   |
| Pauser is compromised         | Every stack revoked and registrations paused until the administrator restores them. No funds move.                                                                                                                                                                                                                                                                                                                                             |
| A stack's owner               | Malicious: misuse of that engine's settings, as for any Veda stack ([Veda](veda.md#vedaengine)). Unresponsive: its stack stays on replaced modules after a publication. No other stack is affected.                                                                                                                                                                                                                                            |
| Administrator                 | Unchanged in power. One publication is now offered to every stack, and each stack's owner activates it.                                                                                                                                                                                                                                                                                                                                        |

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
`AllowlistTeller` and `AllowlistQueue` stand in for a Teller with an account allowlist and a Queue
bound to it. The engine in every stack is the released `VedaEngine`, whose own suites are in
[Veda](veda.md#tests).

- `VedaVaultRegistry.t.sol`: who administers a vault, every publication check, that any number of
  released engines bind on one registry, and that a publication moves an engine only when its owner
  activates it.
- `VedaStackFactory.t.sol`: a vault whose modules gate their callers, including end-to-end deposits,
  immediate exits and solved queued exits through a real EarnVault, a job id that builds one engine
  however often it is sent, stacks that activate a publication one owner at a time, and an engine
  left pending across a publication.
- `VedaRoleGranter.t.sol`: the granter's authority surface and pre-grant checks, and a stateful
  invariant that only factory-built contracts ever hold an Earn role and nothing else in the role
  table changes.
- `VedaRoleGranterAllowlist.t.sol`: a vault that opens the Teller to every caller and admits by its
  list. Building lists the engine in the same call, a stack is never reported built while the list
  refuses its engine, revoking delists and stops deposits, exits and queued settlement, the role and
  the listing are each removed when the other cannot be, a direct delisting is not undone, a newly
  published Teller is listed through `relist` before an owner activates it, revoking stops an engine
  on the Teller it uses and on the one it could activate and also delists an engine someone else
  listed, a vault moves from a Teller that gates callers to one that admits by account under the
  same granter and factory, an engine revoked before the vault had a list stays off the one that
  comes later, and a stateful
  invariant that the Teller's list holds the stock solver and exactly the active engines.
- `VedaForwarderSteward.t.sol`: a forwarder built with the vault's solver approved settles with no
  transaction from its owner, the list reaches every forwarder through `seed` and `prune`, and
  `isForwarderReady` follows everything a queued exit needs.

[`test/earn/gas/VedaStackGas.t.sol`](../../../test/earn/gas/VedaStackGas.t.sol) records stack-building gas
in the [gas baseline](../../development/README.md#gas-baseline); run it under the `spend` profile for
Tempo's pricing, as its header shows.
