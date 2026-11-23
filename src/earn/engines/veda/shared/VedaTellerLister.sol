// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {
    IVedaStackFactoryWiring,
    IVedaTellerLister,
    IVedaVaultRegistry
} from "../../../../interfaces/earn/engines/IVedaVaultRegistry.sol";
import { IAuth, IAuthority } from "../../../../interfaces/external/veda/IRolesAuthority.sol";
import { ITellerAllowlist } from "../../../../interfaces/external/veda/ITellerAllowlist.sol";
import { VedaTellerAllowlist } from "./VedaTellerAllowlist.sol";

/// @title VedaTellerLister
/// @notice Puts the engines a {VedaStackFactory} builds on the account allowlist of the vault's
///         published Teller, and takes them off it. For a vault whose Teller checks the account whose
///         position changes: there, being allowed to call the Teller is not enough to use it.
///
/// @dev WHAT IT HOLDS. The vault's administrator lets this contract call `setAllowedAccounts` on the
///      Teller. That function takes any accounts, so nothing but this contract's code keeps the
///      permission to Earn engines: it lists only an engine a factory the administrator named asks
///      for, carries to a new Teller only engines it still records as listed, and delists only
///      engines it listed. Its worst failure is a wrong list: an account that may enter and leave the
///      vault without the Teller's share lock, or an engine whose deposits and exits stop. It holds no
///      role over the BoringVault, the RolesAuthority or the Teller's other settings, and never moves
///      shares or assets.
///
///      LOCKSTEP. The list lives in the Teller, so a newly published Teller starts without the vault's
///      engines, and a Teller published again still has the list it had. After every publication of a
///      Teller, {relist} carries the recorded engines onto it and {redelist} takes the delisted ones
///      off it. Both are open to anyone and write only what this contract already recorded.
///
///      THE RECORD IS NOT THE LIST. `listedOn` says what this contract last wrote. The administrator
///      can change the Teller's list directly, and this contract does not learn of it. {relist} does
///      not repeat its latest listing, so a direct delisting on the Teller that listing was made on
///      stays, but the engine is carried to the next Teller published; only {revokeListing} or the
///      factory's `revokeEngine` keeps an engine off. A direct listing of an engine this contract
///      delisted is removed by {redelist}; reinstating the engine through its factory is what lists
///      it again. A Teller that stops enforcing its list admits everyone whatever is recorded here.
/// The lister's wiring never changes.
/// @custom:invariant address(registry) != address(0)
contract VedaTellerLister is IVedaTellerLister {
    /// @dev Marks an engine this contract listed and has since delisted. Never a Teller.
    address private constant DELISTED = address(1);

    /// @notice The vault's registry: its published Teller is the one this contract lists on, and every
    ///         factory this lister serves must build on it.
    IVedaVaultRegistry public immutable registry;

    /// @notice The stack factories the vault's administrator has named: the only callers that list.
    mapping(address factory => bool named) public isFactory;
    /// @notice The Teller this contract last listed `engine` on. Zero for an account it never listed,
    ///         and `address(1)` for an engine it has since delisted.
    mapping(address engine => address teller) public listedOn;

    event StackFactoryChanged(address indexed factory, bool named);
    event EngineListingChanged(address indexed engine, address indexed teller, bool listed);
    /// @notice The engine is recorded as delisted, and the Teller did not take the change. {redelist}
    ///         finishes it.
    event EngineDelistingDeferred(address indexed engine, address indexed teller);

    error CannotListOnTeller(address teller);
    error FactoryNotNamed(address factory);
    error FactoryNotWired(address factory);
    error InvalidAccount(address account);
    error InvalidListerWiring(address account);
    error ListingFailed(address engine, address teller, bool listed);
    error ListNotEnforced(address teller);
    error ListWritableByAnyone(address teller);
    error NotFactory(address caller);
    error NotListedEngine(address engine);
    error NotVaultAdmin(address caller);
    error QueueNotBound(address queue, address teller);
    error RegistryMismatch(address expected, address actual);
    error SolverNotListed(address solver, address teller);
    error ZeroAddress();

    modifier onlyVaultAdmin() {
        if (!registry.isVaultAdmin(msg.sender)) revert NotVaultAdmin(msg.sender);
        _;
    }

    constructor(IVedaVaultRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        if (address(registry_).code.length == 0) revert InvalidListerWiring(address(registry_));
        registry = registry_;
    }

    /// @notice Names a stack factory as a caller, or stops accepting one.
    /// @dev Only the vault's administrator. A named factory must report this lister as its Teller lister
    ///      and this lister's registry as its own. A factory that is no longer named can neither list
    ///      nor delist; its engines stay listed until the administrator calls {revokeListing}.
    /// @custom:ensures registry.isVaultAdmin(msg.sender) && isFactory[factory] == named
    function setFactory(address factory, bool named) external onlyVaultAdmin {
        if (named) {
            if (factory.code.length == 0) revert FactoryNotWired(factory);
            IVedaStackFactoryWiring wiring = IVedaStackFactoryWiring(factory);
            if (wiring.tellerLister() != address(this) || wiring.registry() != address(registry)) {
                revert FactoryNotWired(factory);
            }
        }
        isFactory[factory] = named;
        emit StackFactoryChanged(factory, named);
    }

    /// @notice Lists `engine` on the published Teller, or delists it.
    /// @dev Only a named factory, which asks only for engines it built. Listing reverts unless the
    ///      Teller reports the engine listed. Delisting always records the engine as delisted, so that
    ///      nothing here can list it again, and returns whether the Teller took the change; when it
    ///      did not, {redelist} finishes it. Delisting stops the engine's deposits and immediate exits
    ///      together and, on a Queue bound to the Teller, its new requests and the settlement of the
    ///      ones already queued; cancellation is the Queue's to allow.
    /// @custom:ensures isFactory[msg.sender] && isListedEngine(engine) == listed
    function setEngineListed(address engine, bool listed) external returns (bool applied) {
        if (!isFactory[msg.sender]) revert NotFactory(msg.sender);
        if (!listed) return _delist(engine);
        _list(engine);
        return true;
    }

    /// @notice Takes `engine` off the published Teller's list and records it as delisted, so that
    ///         {relist} cannot restore it.
    /// @dev Only the vault's administrator: for an engine whose factory is no longer named, or one the
    ///      administrator took off the Teller's list directly and wants kept off the next Teller.
    /// @custom:ensures registry.isVaultAdmin(msg.sender) && !isListedEngine(engine)
    function revokeListing(address engine) external onlyVaultAdmin returns (bool applied) {
        return _delist(engine);
    }

    /// @notice Carries recorded engines onto the Teller published now.
    /// @dev Open to anyone, since it writes only what a named factory already asked for. An engine
    ///      whose latest listing by this contract was on this Teller is skipped, so a listing the
    ///      administrator has since removed there directly is not restored. Accounts this contract
    ///      does not record as listed are skipped as well, so one revoked engine does not fail a batch.
    /// @return carried How many engines were listed.
    function relist(address[] calldata engines) external returns (uint256 carried) {
        address teller = address(registry.teller());
        address[] memory accounts = new address[](engines.length);
        for (uint256 i = 0; i < engines.length; i++) {
            address engine = engines[i];
            address last = listedOn[engine];
            if (last == address(0) || last == DELISTED || last == teller) continue;
            listedOn[engine] = teller;
            accounts[carried++] = engine;
        }
        if (carried == 0) return 0;
        accounts = _firstOf(accounts, carried);
        ITellerAllowlist(teller).setAllowedAccounts(accounts, true);
        for (uint256 i = 0; i < carried; i++) {
            if (!ITellerAllowlist(teller).allowedAccounts(accounts[i])) {
                revert ListingFailed(accounts[i], teller, true);
            }
            emit EngineListingChanged(accounts[i], teller, true);
        }
    }

    /// @notice Takes engines this contract delisted off the Teller published now.
    /// @dev Open to anyone, since it only removes what a pauser or the administrator already removed.
    ///      It is what keeps a delisted engine off a Teller the engine was listed on by another route:
    ///      a Teller published again with its old list, one the administrator listed engines on before
    ///      publishing it, or one that did not take the change when the engine was delisted. Accounts
    ///      this contract does not record as delisted are skipped.
    /// @return removed How many engines were taken off.
    function redelist(address[] calldata engines) external returns (uint256 removed) {
        address teller = address(registry.teller());
        address[] memory accounts = new address[](engines.length);
        for (uint256 i = 0; i < engines.length; i++) {
            if (listedOn[engines[i]] == DELISTED) accounts[removed++] = engines[i];
        }
        if (removed == 0) return 0;
        accounts = _firstOf(accounts, removed);
        ITellerAllowlist(teller).setAllowedAccounts(accounts, false);
        for (uint256 i = 0; i < removed; i++) {
            if (ITellerAllowlist(teller).allowedAccounts(accounts[i])) {
                revert ListingFailed(accounts[i], teller, false);
            }
            emit EngineListingChanged(accounts[i], teller, false);
        }
    }

    /// @notice Whether this contract listed `engine` and has not since delisted it.
    function isListedEngine(address engine) public view returns (bool) {
        address last = listedOn[engine];
        return last != address(0) && last != DELISTED;
    }

    /// @notice Reverts unless this lister serves `publishedRegistry`, accepts `factory`, and the list
    ///         it writes is what admits an account to the vault published there.
    /// @dev The last call of the administrator's setup batch, naming the registry it published on and
    ///      the factory it named. A lister built over another registry would list on whatever Teller
    ///      that registry reports, for whoever that registry calls an administrator. It also requires
    ///      that the published Teller enforces its list in both directions, that this contract may
    ///      write it and an account holding no role may not, and that a published Queue applies that
    ///      same list and its stock solver is on it; without those, listing an engine admits nothing,
    ///      delisting one stops nothing, or queued exits cannot settle. It cannot show that no other
    ///      account holds the role that writes the list. This contract must not itself be on the list,
    ///      which is how it tells an enforced list from an idle one. Run it again as the last call of
    ///      every publication.
    function assertSetup(IVedaVaultRegistry publishedRegistry, address factory) external view {
        if (address(publishedRegistry) != address(registry)) {
            revert RegistryMismatch(address(registry), address(publishedRegistry));
        }
        if (!isFactory[factory]) revert FactoryNotNamed(factory);
        address teller = address(registry.teller());
        (bool depositChecked, bool depositAllowed) = VedaTellerAllowlist.tryIsDepositAllowed(teller, address(this));
        (bool withdrawChecked, bool withdrawAllowed) = VedaTellerAllowlist.tryIsWithdrawAllowed(teller, address(this));
        if (!depositChecked || !withdrawChecked || !_mayWriteList(teller, address(this))) {
            revert CannotListOnTeller(teller);
        }
        if (depositAllowed || withdrawAllowed) revert ListNotEnforced(teller);
        // The registry holds no role, so a Teller that lets it write the list lets everyone.
        if (_mayWriteList(teller, address(registry))) revert ListWritableByAnyone(teller);
        address queue = address(registry.queue());
        if (queue != address(0)) {
            (bool queueChecks, address queueTeller) = VedaTellerAllowlist.tryQueueTeller(queue);
            if (!queueChecks || queueTeller != teller) revert QueueNotBound(queue, teller);
            address solver = address(registry.solver());
            (bool readable, bool solverListed) = VedaTellerAllowlist.tryAllowedAccounts(teller, solver);
            if (!readable || !solverListed) revert SolverNotListed(solver, teller);
        }
    }

    function _list(address engine) private {
        if (engine == address(0) || engine.code.length == 0) revert InvalidAccount(engine);
        address teller = address(registry.teller());
        listedOn[engine] = teller;

        ITellerAllowlist(teller).setAllowedAccounts(_one(engine), true);
        // A Teller that accepted the call without recording it would leave the record above wrong.
        if (!ITellerAllowlist(teller).allowedAccounts(engine)) revert ListingFailed(engine, teller, true);
        emit EngineListingChanged(engine, teller, true);
    }

    /// @dev Records the engine as delisted whatever the Teller does, so a Teller that cannot be
    ///      written (one without a list, or one this contract has no permission on) never keeps an
    ///      engine eligible for {relist}. `applied` says the Teller's list no longer holds the engine,
    ///      not that the Teller refuses it: an unenforced list refuses no one. Only an account this
    ///      contract listed can be delisted.
    function _delist(address engine) private returns (bool applied) {
        if (listedOn[engine] == address(0)) revert NotListedEngine(engine);
        address teller = address(registry.teller());
        listedOn[engine] = DELISTED;

        if (teller.code.length != 0) {
            try ITellerAllowlist(teller).setAllowedAccounts(_one(engine), false) {
                (bool supported, bool listed) = VedaTellerAllowlist.tryAllowedAccounts(teller, engine);
                applied = supported && !listed;
            } catch { }
        }
        if (applied) emit EngineListingChanged(engine, teller, false);
        else emit EngineDelistingDeferred(engine, teller);
    }

    /// @dev Whether the Teller would accept `setAllowedAccounts` from `account`, as the Teller asks it.
    function _mayWriteList(address teller, address account) private view returns (bool) {
        if (IAuth(teller).owner() == account) return true;
        address authority = IAuth(teller).authority();
        return authority.code.length != 0
            && IAuthority(authority).canCall(account, teller, ITellerAllowlist.setAllowedAccounts.selector);
    }

    function _one(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    /// @dev The first `length` entries of `accounts`.
    function _firstOf(address[] memory accounts, uint256 length) private pure returns (address[] memory first) {
        first = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            first[i] = accounts[i];
        }
    }
}
