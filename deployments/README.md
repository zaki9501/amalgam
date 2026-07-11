# Ammalgam Deployments
Latest `core-v1` and `peripheral` contract deployed addresses, ABIs and interfaces

## Sepolia

### v0.11.0

| Name                            | Address                                                                                      | Interface |
|---------------------------------|--------------------------------------------------------------------------------------------| ------------- |
| Ammalgam Factory               | [`0x5a6A9C26587F80eF235903e6de814cB35CF26307`](https://sepolia.etherscan.io/address/0x5a6A9C26587F80eF235903e6de814cB35CF26307) | [IAmmalgamFactory](./interfaces/factories/IAmmalgamFactory.sol)
| Ammalgam Peripheral            | [`0xAfFC6c525660480dA9656165490aA9c27E5ea9B3`](https://sepolia.etherscan.io/address/0xAfFC6c525660480dA9656165490aA9c27E5ea9B3) | [IPeripheral](./interfaces/IPeripheral.sol)
| Ammalgam Pair Creator          | [`0x4194bF08fb7Ff37e96715492a5a713A44Ada272E`](https://sepolia.etherscan.io/address/0x4194bF08fb7Ff37e96715492a5a713A44Ada272E) | —
| Ammalgam Swap Helper           | [`0xd84A2e3D5f68e299823b44557102bF2BfdC16185`](https://sepolia.etherscan.io/address/0xd84A2e3D5f68e299823b44557102bF2BfdC16185) | [IPeripheralSwapHelper](./interfaces/IPeripheralSwapHelper.sol)
| Ammalgam TWAP State            | [`0xf0E5Ec52B0F03A9ef5B1F12F1789Df3A1818C5B7`](https://sepolia.etherscan.io/address/0xf0E5Ec52B0F03A9ef5B1F12F1789Df3A1818C5B7) | [ISaturationAndGeometricTWAPState](./interfaces/ISaturationAndGeometricTWAPState.sol)

This repo contains the `interfaces` for the `core-v1` contracts of the Ammalgam Protocol. We will be exposing more once we have completed audits and are closer to launching.

The main two contracts are the [IAmmalgamFactory](./interfaces/factories/IAmmalgamFactory.sol) and the [IAmmalgamPair](./interfaces/IAmmalgamPair.sol). These work similarly
to the Uniswap V2 Factory and Pair. Note that the `IAmmalgamPair` inherits the [ITokenController](./interfaces/tokens/ITokenController.sol) which exposes additional information
about the pair.

The pair mints 6 different tokens for each possible position, mint L, deposit X or Y, borrow X or Y, and borrow L. Each token type can be found in the [tokens folder](./interfaces/tokens).

The [IAmmalgamCallee](./interfaces/callbacks/IAmmalgamCallee.sol) can be used to run operations in the middle of the `swap`, `borrow`, and `borrowLiqudity` calls in the Ammalgam Pair.

If you have additional questions please reach out in Discord, and we will attempt to help. 