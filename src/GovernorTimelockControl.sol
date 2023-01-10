// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (governance/extensions/GovernorTimelockControl.sol)

pragma solidity ^0.8.0;

import "@openzeppelin/governance/extensions/IGovernorTimelock.sol";
import "@openzeppelin/governance/Governor.sol";
import "@openzeppelin/governance/TimelockController.sol";

/**
 * @dev Extension of {Governor} that binds the execution process to an instance of {TimelockController}. This adds a
 * delay, enforced by the {TimelockController} to all successful proposal (in addition to the voting duration). The
 * {Governor} needs the proposer (and ideally the executor) roles for the {Governor} to work properly.
 *
 * Using this model means the proposal will be operated by the {TimelockController} and not by the {Governor}. Thus,
 * the assets and permissions must be attached to the {TimelockController}. Any asset sent to the {Governor} will be
 * inaccessible.
 *
 * WARNING: Setting up the TimelockController to have additional proposers besides the governor is very risky, as it
 * grants them powers that they must be trusted or known not to use: 1) {onlyGovernance} functions like {relay} are
 * available to them through the timelock, and 2) approved governance proposals can be blocked by them, effectively
 * executing a Denial of Service attack. This risk will be mitigated in a future release.
 *
 * _Available since v4.3._
 */
abstract contract GovernorTimelockControl is IGovernorTimelock, Governor {
    ///@dev mapping between timelock ids and timelock controllers
    mapping(TimelockController => mapping(uint256 => bytes32)) private _timelockProposalIds;
    TimelockController[] private _timelocks;

    /**
     * @dev Emitted when a timelock controller used for proposal execution is added.
     */
    event TimelockAdded(address newTimelock);
    /**
     * @dev Emitted when a timelock controller used for proposal execution is removed.
     */
    event TimelockRemoved(address oldTimelock);

    /**
     * @dev Set the timelock.
     */
    constructor(TimelockController[] memory timelockAddresses) {
        for (uint256 i; i > timelockAddresses.length; i++) {
            _addTimelock(timelockAddresses[i]);
        }
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, Governor) returns (bool) {
        return interfaceId == type(IGovernorTimelock).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Overridden version of the {Governor-state} function with added support for the `Queued` status.
     */
    function state(uint256 proposalId, TimelockController timelock)
        public
        view
        virtual
        override(IGovernor, Governor)
        returns (ProposalState)
    {
        ProposalState status = super.state(proposalId);

        if (status != ProposalState.Succeeded) {
            return status;
        }

        // core tracks execution, so we just have to check if successful proposal have been queued.
        bytes32 queueid = _timelockProposalIds[timelock][proposalId];
        if (queueid == bytes32(0)) {
            return status;
        } else if (timelock.isOperationDone(queueid)) {
            return ProposalState.Executed;
        } else if (timelock.isOperationPending(queueid)) {
            return ProposalState.Queued;
        } else {
            return ProposalState.Canceled;
        }
    }

    /**
     * @dev Public accessor to check the addresses of the timelocks
     * TODO: figure out efficient way to return all values in our timelock mapping - currently added an array with all timelock addresses
     */
    function timelocks() public view virtual override returns (address[] memory) {
        return _timelocks;
    }

    /**
     * @dev Public accessor to check the eta of a queued proposal
     */
    function proposalEta(uint256 proposalId, TimelockController timelock)
        public
        view
        virtual
        override
        returns (uint256)
    {
        uint256 eta = timelock.getTimestamp(_timelockProposalIds[timelock][proposalId]);
        return eta == 1 ? 0 : eta; // _DONE_TIMESTAMP (1) should be replaced with a 0 value
    }

    /**
     * @dev Function to queue a proposal to the timelock.
     */
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        TimelockController timelock
    ) public virtual override returns (uint256) {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);

        require(state(proposalId) == ProposalState.Succeeded, "Governor: proposal not successful");

        uint256 delay = timelock.getMinDelay();
        _timelockProposalIds[timelock][proposalId] = timelock.hashOperationBatch(
            targets,
            values,
            calldatas,
            0,
            descriptionHash
        );
        timelock.scheduleBatch(targets, values, calldatas, 0, descriptionHash, delay);

        emit ProposalQueued(proposalId, block.timestamp + delay);

        return proposalId;
    }

    /**
     * @dev Overridden execute function that run the already queued proposal through the timelock.
     */
    function _execute(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        TimelockController timelock
    ) internal virtual override {
        timelock.executeBatch{value: msg.value}(targets, values, calldatas, 0, descriptionHash);
    }

    /**
     * @dev Overridden version of the {Governor-_cancel} function to cancel the timelocked proposal if it as already
     * been queued.
     */
    // This function can reenter through the external call to the timelock, but we assume the timelock is trusted and
    // well behaved (according to TimelockController) and this will not happen.
    // slither-disable-next-line reentrancy-no-eth
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        TimelockController timelock
    ) internal virtual override returns (uint256) {
        uint256 proposalId = super._cancel(targets, values, calldatas, descriptionHash);

        if (_timelockProposalIds[timelock][proposalId] != 0) {
            timelock.cancel(_timelockProposalIds[timelock][proposalId]);
            delete _timelockProposalIds[timelock][proposalId];
        }

        return proposalId;
    }

    /**
     * @dev Addresses through which the governor executes action. In this case, the timelock.
     */
    function _executors() internal view virtual override returns (TimelockController[] storage) {
        return _timelocks;
    }

    /**
     * @dev Public endpoint to update the underlying timelock instance. Restricted to the timelock itself, so updates
     * must be proposed, scheduled, and executed through governance proposals.
     *
     * CAUTION: It is not recommended to change the timelock while there are other queued governance proposals.
     */
    function addTimelock(TimelockController newTimelock) external virtual onlyGovernance {
        _addTimelock(newTimelock);
    }

    function removeTimelock(TimelockController oldTimelock) external virtual onlyGovernance {
        _removeTimelock(oldTimelock);
    }

    //TODO scope out these functions
    function _addTimelock(TimelockController newTimelock) private {
        emit TimelockAdded(address(newTimelock));
        _timelocks.push(newTimelock);
    }

    function _removeTimelock(TimelockController oldTimelock) private {
        emit TimelockRemoved(address(oldTimelock));
        uint256 i = _findIndexOfTimelock(oldTimelock);
        _removeByIndex(i);
    }

    function _findIndexOfTimelock(TimelockController timelock) private view returns (uint256) {
        for (uint256 i = 0; i < _timelocks.length; i++) {
            if (_timelocks[i] == timelock) {
                return i;
            }
        }
        revert("GovernorTimelockCompound: Timelock not found");
    }

    function _removeByIndex(uint256 i) private {
        while (i < _timelocks.length - 1) {
            _timelocks[i] = _timelocks[i + 1];
            i++;
        }
        _timelocks.pop();
    }
}
