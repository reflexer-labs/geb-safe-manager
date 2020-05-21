// Copyright (C) 2018-2020 Maker Ecosystem Growth Holdings, INC.

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.5.15;

import { Logging } from "geb/Logging.sol";

contract CDPEngineLike {
    function cdps(bytes32, address) public view returns (uint, uint);
    function approveCDPModification(address) public;
    function transferCollateral(bytes32, address, address, uint) public;
    function transferInternalCoins(address, address, uint) public;
    function modifyCDPCollateralization(bytes32, address, address, address, int, int) public;
    function transferCDPCollateralAndDebt(bytes32, address, address, int, int) public;
}

contract RewardDistributorLike {
    function claimCDPManagementRewards(bytes32,address,address) external returns (bool);
}

contract CollateralLike {
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

contract CDPHandler {
    constructor(address cdpEngine) public {
        CDPEngineLike(cdpEngine).approveCDPModification(msg.sender);
    }
}

contract GebCdpManager is Logging {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
    * @notice Add auth to an account
    * @param account Account to add auth to
    */
    function addAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 1;
    }
    /**
    * @notice Remove auth from an account
    * @param account Account to remove auth from
    */
    function removeAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "GebCdpManager/account-not-authorized");
        _;
    }

    address                   public cdpEngine;
    uint                      public cdpi;               // Auto incremental
    mapping (uint => address) public cdps;               // CDPId => CDPHandler
    mapping (uint => List)    public cdpList;            // CDPId => Prev & Next CDPIds (double linked list)
    mapping (uint => address) public ownsCDP;            // CDPId => Owner
    mapping (uint => bytes32) public collateralTypes;    // CDPId => CollateralType

    mapping (address => uint) public firstCDPID;     // Owner => First CDPId
    mapping (address => uint) public lastCDPID;      // Owner => Last CDPId
    mapping (address => uint) public cdpCount;       // Owner => Amount of CDPs

    mapping (
        address => mapping (
            uint => mapping (
                address => uint
            )
        )
    ) public cdpCan;                            // Owner => CDPId => Allowed Addr => True/False

    mapping (
        address => mapping (
            address => uint
        )
    ) public handlerCan;                        // CDP handler => Allowed Addr => True/False

    RewardDistributorLike public rewardDistributor;

    struct List {
        uint prev;
        uint next;
    }

    event NewCdp(address indexed usr, address indexed own, uint indexed cdp);
    event ClaimCDPManagementRewards(address indexed usr, address indexed own, bytes32 collateralType, address cdp);

    modifier cdpAllowed(
        uint cdp
    ) {
        require(msg.sender == ownsCDP[cdp] || cdpCan[ownsCDP[cdp]][cdp][msg.sender] == 1, "cdp-not-allowed");
        _;
    }

    modifier handlerAllowed(
        address handler
    ) {
        require(
          msg.sender == handler ||
          handlerCan[handler][msg.sender] == 1,
          "internal-system-cdp-not-allowed"
        );
        _;
    }

    constructor(address cdpEngine_) public {
        authorizedAccounts[msg.sender] = 1;
        cdpEngine = cdpEngine_;
    }

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function toInt(uint x) internal pure returns (int y) {
        y = int(x);
        require(y >= 0);
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, address addr) external emitLog isAuthorized {
        if (parameter == "rewardDistributor") rewardDistributor = RewardDistributorLike(addr);
        else revert("modify-unrecognized-param");
    }

    // --- CDP Manipulation ---

    // Allow/disallow a usr address to manage the cdp
    function allowCDP(
        uint cdp,
        address usr,
        uint ok
    ) public cdpAllowed(cdp) {
        cdpCan[ownsCDP[cdp]][cdp][usr] = ok;
    }

    // Allow/disallow a usr address to quit to the the sender handler
    function allowHandler(
        address usr,
        uint ok
    ) public {
        handlerCan[msg.sender][usr] = ok;
    }

    // Open a new cdp for a given usr address.
    function openCDP(
        bytes32 collateralType,
        address usr
    ) public emitLog returns (uint) {
        require(usr != address(0), "usr-address-0");

        cdpi = add(cdpi, 1);
        cdps[cdpi] = address(new CDPHandler(cdpEngine));
        ownsCDP[cdpi] = usr;
        collateralTypes[cdpi] = collateralType;

        // Add new CDP to double linked list and pointers
        if (firstCDPID[usr] == 0) {
            firstCDPID[usr] = cdpi;
        }
        if (lastCDPID[usr] != 0) {
            cdpList[cdpi].prev = lastCDPID[usr];
            cdpList[lastCDPID[usr]].next = cdpi;
        }
        lastCDPID[usr] = cdpi;
        cdpCount[usr] = add(cdpCount[usr], 1);

        emit NewCdp(msg.sender, usr, cdpi);
        return cdpi;
    }

    // Give the cdp ownership to a dst address.
    function transferCDPOwnership(
        uint cdp,
        address dst
    ) public emitLog cdpAllowed(cdp) {
        require(dst != address(0), "dst-address-0");
        require(dst != ownsCDP[cdp], "dst-already-owner");

        // Remove transferred CDP from double linked list of origin user and pointers
        if (cdpList[cdp].prev != 0) {
            cdpList[cdpList[cdp].prev].next = cdpList[cdp].next;    // Set the next pointer of the prev cdp (if exists) to the next of the transferred one
        }
        if (cdpList[cdp].next != 0) {                               // If wasn't the last one
            cdpList[cdpList[cdp].next].prev = cdpList[cdp].prev;    // Set the prev pointer of the next cdp to the prev of the transferred one
        } else {                                                    // If was the last one
            lastCDPID[ownsCDP[cdp]] = cdpList[cdp].prev;            // Update last pointer of the owner
        }
        if (firstCDPID[ownsCDP[cdp]] == cdp) {                      // If was the first one
            firstCDPID[ownsCDP[cdp]] = cdpList[cdp].next;           // Update first pointer of the owner
        }
        cdpCount[ownsCDP[cdp]] = sub(cdpCount[ownsCDP[cdp]], 1);

        // Transfer ownership
        ownsCDP[cdp] = dst;

        // Add transferred CDP to double linked list of destiny user and pointers
        cdpList[cdp].prev = lastCDPID[dst];
        cdpList[cdp].next = 0;
        if (lastCDPID[dst] != 0) {
            cdpList[lastCDPID[dst]].next = cdp;
        }
        if (firstCDPID[dst] == 0) {
            firstCDPID[dst] = cdp;
        }
        lastCDPID[dst] = cdp;
        cdpCount[dst] = add(cdpCount[dst], 1);
    }

    // Frob the cdp keeping the generated COIN or collateral freed in the cdp handler address.
    function modifyCDPCollateralization(
        uint cdp,
        int deltaCollateral,
        int deltaDebt
    ) public emitLog cdpAllowed(cdp) {
        address cdpHandler = cdps[cdp];
        CDPEngineLike(cdpEngine).modifyCDPCollateralization(
            collateralTypes[cdp],
            cdpHandler,
            cdpHandler,
            cdpHandler,
            deltaCollateral,
            deltaDebt
        );
    }

    // Transfer wad amount of cdp collateral from the cdp address to a dst address.
    function transferCollateral(
        uint cdp,
        address dst,
        uint wad
    ) public emitLog cdpAllowed(cdp) {
        CDPEngineLike(cdpEngine).transferCollateral(collateralTypes[cdp], cdps[cdp], dst, wad);
    }

    // Transfer wad amount of any type of collateral (collateralType) from the cdp address to a dst address.
    // This function has the purpose to take away collateral from the system that doesn't correspond to the cdp but was sent there wrongly.
    function transferCollateral(
        bytes32 collateralType,
        uint cdp,
        address dst,
        uint wad
    ) public emitLog cdpAllowed(cdp) {
        CDPEngineLike(cdpEngine).transferCollateral(collateralType, cdps[cdp], dst, wad);
    }

    // Transfer rad amount of COIN from the cdp address to a dst address.
    function transferInternalCoins(
        uint cdp,
        address dst,
        uint rad
    ) public emitLog cdpAllowed(cdp) {
        CDPEngineLike(cdpEngine).transferInternalCoins(cdps[cdp], dst, rad);
    }

    // Quit the system, migrating the cdp (lockedCollateral, generatedDebt) to a different dst handler
    function quitSystem(
        uint cdp,
        address dst
    ) public emitLog cdpAllowed(cdp) handlerAllowed(dst) {
        (uint lockedCollateral, uint generatedDebt) = CDPEngineLike(cdpEngine).cdps(collateralTypes[cdp], cdps[cdp]);
        int deltaCollateral = toInt(lockedCollateral);
        int deltaDebt = toInt(generatedDebt);
        CDPEngineLike(cdpEngine).transferCDPCollateralAndDebt(
            collateralTypes[cdp],
            cdps[cdp],
            dst,
            deltaCollateral,
            deltaDebt
        );
    }

    // Import a position from src handler to the handler owned by cdp
    function enterSystem(
        address src,
        uint cdp
    ) public emitLog handlerAllowed(src) cdpAllowed(cdp) {
        (uint lockedCollateral, uint generatedDebt) = CDPEngineLike(cdpEngine).cdps(collateralTypes[cdp], src);
        int deltaCollateral = toInt(lockedCollateral);
        int deltaDebt = toInt(generatedDebt);
        CDPEngineLike(cdpEngine).transferCDPCollateralAndDebt(
            collateralTypes[cdp],
            src,
            cdps[cdp],
            deltaCollateral,
            deltaDebt
        );
    }

    // Move a position from cdpSrc handler to the cdpDst handler
    function moveCDP(
        uint cdpSrc,
        uint cdpDst
    ) public emitLog cdpAllowed(cdpSrc) cdpAllowed(cdpDst) {
        require(collateralTypes[cdpSrc] == collateralTypes[cdpDst], "non-matching-cdps");
        (uint lockedCollateral, uint generatedDebt) = CDPEngineLike(cdpEngine).cdps(collateralTypes[cdpSrc], cdps[cdpSrc]);
        int deltaCollateral = toInt(lockedCollateral);
        int deltaDebt = toInt(generatedDebt);
        CDPEngineLike(cdpEngine).transferCDPCollateralAndDebt(
            collateralTypes[cdpSrc],
            cdps[cdpSrc],
            cdps[cdpDst],
            deltaCollateral,
            deltaDebt
        );
    }

    // Claim rewards for good cdp management
    function claimCDPManagementRewards(
        uint cdp,
        address lad
    ) public emitLog cdpAllowed(cdp) {
        address who = (lad != address(0)) ? lad : msg.sender;
        require(rewardDistributor.claimCDPManagementRewards(collateralTypes[cdp], cdps[cdp], who) == true, "cannot-claim");
        emit ClaimCDPManagementRewards(msg.sender, who, collateralTypes[cdp], cdps[cdp]);
    }
}