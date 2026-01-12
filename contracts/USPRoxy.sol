// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev זהו חוזה הפרוקסי שיחזיק את ה-State (היתרות והבעלים).
 * הוא יפנה את כל הקריאות לחוזה הלוגיקה (Implementation) שלך.
 */
contract USProxy is ERC1967Proxy {
    
    /**
     * @param implementation - הכתובת של חוזה הלוגיקה שפרסת (ERCUltraESH)
     * @param _data - הנתונים לאתחול (הקידוד של הפונקציה initialize)
     */
    constructor(address implementation, bytes memory _data)
        ERC1967Proxy(implementation, _data)
    {}
}