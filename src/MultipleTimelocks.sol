// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

/**
 * @title MultipleTimelock
 * @author Theo - Llama
 * @notice modification of the TimelockController & Governance contract to work with multiple timelocks, & allowing governance to add more timelocks to the TimelockController if they want
 */

import "openzeppelin-contracts/governance/extensions/GovernorTimelockControl.sol";

contract MultipleTimelocks is GovernorTimelockControl {}
