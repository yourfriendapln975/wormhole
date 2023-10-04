// contracts/Messages.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./Getters.sol";
import "./Structs.sol";
import "./libraries/relayer/BytesParsing.sol";

import "forge-std/console.sol";

contract OptimizedMessages is Getters {
    using BytesParsing for bytes;

    function parseAndVerifyVMOptimized(
        bytes calldata encodedVM, 
        bytes calldata guardianSet, 
        uint32 guardianSetIndex
    ) public view returns (Structs.VM memory vm, bool valid, string memory reason) {
        // Verify that the specified guardian set is a valid. 
        require(
            getGuardianSetHash(guardianSetIndex) == keccak256(guardianSet), 
            "invalid guardian set"
        );

        // TODO: Optimize parsing function. 
        vm = parseVM(encodedVM);

        // Verify that the VM is signed with the same guardian set that was specified.
        require(vm.guardianSetIndex == guardianSetIndex, "mismatched guardian set index");

        (valid, reason) = verifyVMInternal(vm, parseGuardianSetOptimized(guardianSet), false);
    }

    function parseGuardianSetOptimized(bytes calldata guardianSetData) public pure returns (Structs.GuardianSet memory guardianSet) {
        // Fetch the guardian set length.
        uint256 endGuardianKeyIndex = guardianSetData.length - 4; 
        uint256 guardianCount = endGuardianKeyIndex / 20; 

        guardianSet = Structs.GuardianSet({
            keys : new address[](guardianCount),
            expirationTime : 0
        });
        (guardianSet.expirationTime, ) = guardianSetData.asUint32Unchecked(endGuardianKeyIndex);

        uint256 offset = 0;
        for(uint256 i = 0; i < guardianCount;) {
            (guardianSet.keys[i], offset) = guardianSetData.asAddressUnchecked(offset);
            unchecked { 
                ++i; 
            } 
        } 
    } 

    /**
    * @dev `verifyVMInternal` serves to validate an arbitrary vm against a valid Guardian set
    * if checkHash is set then the hash field of the vm is verified against the hash of its contents
    * in the case that the vm is securely parsed and the hash field can be trusted, checkHash can be set to false
    * as the check would be redundant
    */
    function verifyVMInternal(Structs.VM memory vm, Structs.GuardianSet memory guardianSet, bool checkHash) internal view returns (bool valid, string memory reason) {
        /**
         * Verify that the hash field in the vm matches with the hash of the contents of the vm if checkHash is set
         * WARNING: This hash check is critical to ensure that the vm.hash provided matches with the hash of the body.
         * Without this check, it would not be safe to call verifyVM on it's own as vm.hash can be a valid signed hash
         * but the body of the vm could be completely different from what was actually signed by the guardians
         */
        if(checkHash){
            bytes memory body = abi.encodePacked(
                vm.timestamp,
                vm.nonce,
                vm.emitterChainId,
                vm.emitterAddress,
                vm.sequence,
                vm.consistencyLevel,
                vm.payload
            );

            bytes32 vmHash = keccak256(abi.encodePacked(keccak256(body)));

            if(vmHash != vm.hash){
                return (false, "vm.hash doesn't match body");
            }
        }

        uint256 guardianCount = guardianSet.keys.length;

       /**
        * @dev Checks whether the guardianSet has zero keys
        * WARNING: This keys check is critical to ensure the guardianSet has keys present AND to ensure
        * that guardianSet key size doesn't fall to zero and negatively impact quorum assessment.  If guardianSet
        * key length is 0 and vm.signatures length is 0, this could compromise the integrity of both vm and
        * signature verification.
        */
        if(guardianCount == 0){
            return (false, "invalid guardian set");
        }

        /// @dev Checks if VM guardian set index matches the current index (unless the current set is expired).
        if(vm.guardianSetIndex != getCurrentGuardianSetIndex() && guardianSet.expirationTime < block.timestamp){
            return (false, "guardian set has expired");
        }

       /**
        * @dev We're using a fixed point number transformation with 1 decimal to deal with rounding.
        *   WARNING: This quorum check is critical to assessing whether we have enough Guardian signatures to validate a VM
        *   if making any changes to this, obtain additional peer review. If guardianSet key length is 0 and
        *   vm.signatures length is 0, this could compromise the integrity of both vm and signature verification.
        */
        if (vm.signatures.length < quorum(guardianCount)){
            return (false, "no quorum");
        }

        /// @dev Verify the proposed vm.signatures against the guardianSet
        (bool signaturesValid, string memory invalidReason) = verifySignatures(vm.hash, vm.signatures, guardianSet);
        if(!signaturesValid){
            return (false, invalidReason);
        }

        /// If we are here, we've validated the VM is a valid multi-sig that matches the guardianSet.
        return (true, "");
    }


    /**
     * @dev verifySignatures serves to validate arbitrary sigatures against an arbitrary guardianSet
     *  - it intentionally does not solve for expectations within guardianSet (you should use verifyVM if you need these protections)
     *  - it intentioanlly does not solve for quorum (you should use verifyVM if you need these protections)
     *  - it intentionally returns true when signatures is an empty set (you should use verifyVM if you need these protections)
     */
    function verifySignatures(bytes32 hash, Structs.Signature[] memory signatures, Structs.GuardianSet memory guardianSet) public pure returns (bool valid, string memory reason) {
        uint8 lastIndex = 0;
        uint256 sigCount = signatures.length;
        uint256 guardianCount = guardianSet.keys.length;
        for (uint i = 0; i < sigCount;) {
            Structs.Signature memory sig = signatures[i];
            address signatory = ecrecover(hash, sig.v, sig.r, sig.s);
            // ecrecover returns 0 for invalid signatures. We explicitly require valid signatures to avoid unexpected
            // behaviour due to the default storage slot value also being 0.
            require(signatory != address(0), "ecrecover failed with signature");

            /// Ensure that provided signature indices are ascending only
            require(i == 0 || sig.guardianIndex > lastIndex, "signature indices must be ascending");
            lastIndex = sig.guardianIndex;

            /// @dev Ensure that the provided signature index is within the
            /// bounds of the guardianSet. This is implicitly checked by the array
            /// index operation below, so this check is technically redundant.
            /// However, reverting explicitly here ensures that a bug is not
            /// introduced accidentally later due to the nontrivial storage
            /// semantics of solidity.
            require(sig.guardianIndex < guardianCount, "guardian index out of bounds");

            /// Check to see if the signer of the signature does not match a specific Guardian key at the provided index
            if(signatory != guardianSet.keys[sig.guardianIndex]){
                return (false, "VM signature invalid");
            }

            unchecked { i += 1; }
        }

        /// If we are here, we've validated that the provided signatures are valid for the provided guardianSet
        return (true, "");
    }

	function checkPayloadId(
		bytes memory encoded,
		uint256 startOffset,
		uint8 expectedPayloadId
	) private pure returns (uint256 offset) {
		uint8 parsedPayloadId;
		(parsedPayloadId, offset) = encoded.asUint8Unchecked(startOffset);
        require(parsedPayloadId == expectedPayloadId, "invalid payload id");
	}

    /**
     * @dev parseVM serves to parse an encodedVM into a vm struct
     *  - it intentionally performs no validation functions, it simply parses raw into a struct
     */
    function parseVM(bytes memory encodedVM) public view virtual returns (Structs.VM memory vm) {
        uint256 offset = checkPayloadId(encodedVM, 0, 1);
        vm.version = 1;
        (vm.guardianSetIndex, offset) = encodedVM.asUint32Unchecked(offset);

        // Parse sigs. 
        uint256 signersLen;
        (signersLen, offset) = encodedVM.asUint8Unchecked(offset);

        vm.signatures = new Structs.Signature[](signersLen);
        for (uint i = 0; i < signersLen;) {
            (vm.signatures[i].guardianIndex, offset) = encodedVM.asUint8Unchecked(offset);
            (vm.signatures[i].r, offset) = encodedVM.asBytes32Unchecked(offset);
            (vm.signatures[i].s, offset) = encodedVM.asBytes32Unchecked(offset);
            (vm.signatures[i].v, offset) = encodedVM.asUint8Unchecked(offset);
            
            unchecked { 
                vm.signatures[i].v += 27;
                ++i; 
            }
        }

        bytes memory body;
        (body, ) = encodedVM.sliceUnchecked(offset, encodedVM.length - offset);
        vm.hash = keccak256(abi.encodePacked(keccak256(body)));

        // Parse the body
        (vm.timestamp, offset) = encodedVM.asUint32Unchecked(offset);
        (vm.nonce, offset) = encodedVM.asUint32Unchecked(offset);
        (vm.emitterChainId, offset) = encodedVM.asUint16Unchecked(offset);
        (vm.emitterAddress, offset) = encodedVM.asBytes32Unchecked(offset);
        (vm.sequence, offset) = encodedVM.asUint64Unchecked(offset);
        (vm.consistencyLevel, offset) = encodedVM.asUint8Unchecked(offset);
        (vm.payload, offset) = encodedVM.sliceUnchecked(offset, encodedVM.length - offset);

        require(encodedVM.length == offset, "invalid payload length");
    }

    /**
     * @dev quorum serves solely to determine the number of signatures required to acheive quorum
     */
    function quorum(uint numGuardians) public pure virtual returns (uint numSignaturesRequiredForQuorum) {
        // The max number of guardians is 255
        require(numGuardians < 256, "too many guardians");
        return ((numGuardians * 2) / 3) + 1;
    }
}
