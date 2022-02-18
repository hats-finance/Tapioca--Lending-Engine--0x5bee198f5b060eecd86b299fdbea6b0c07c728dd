import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

type TapiocaBar = string;
type Collateral = string;
type Asset = string;
type AssetId = number;
type CollateralId = number;
type Address = string;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy('OracleMock', {
        waitConfirmations: hre.network.live ? 12 : 1,
        from: deployer,
        log: true,
    });

    const oracle = await hre.ethers.getContractAt('OracleMock', (await deployments.get('OracleMock')).address);

    const boba = '0xa18bF3994C0Cc6E3b63ac420308E5383f53120D7';
    const usdc = '0x66a2A913e447d6b4BF33EFbec43aAeF87890FBbc';

    const bar = await hre.ethers.getContractAt('TapiocaBar', (await deployments.get('TapiocaBar')).address);
    await bar.registerAsset(0, boba, hre.ethers.constants.AddressZero, 0);
    await bar.registerAsset(0, usdc, hre.ethers.constants.AddressZero, 0);

    const bobaAssetId = await bar.ids(0, boba, hre.ethers.constants.AddressZero, 0);
    const usdcAssetId = await bar.ids(0, usdc, hre.ethers.constants.AddressZero, 0);

    
    await (await hre.ethers.getSigners())[0].getTransactionCount();
    const deployArgs: [TapiocaBar, Asset, AssetId, Collateral, CollateralId, Address] = [
        bar.address,
        boba,
        bobaAssetId.toNumber(),
        usdc,
        usdcAssetId.toNumber(),
        oracle.address,

    ];
    await deploy('Mixologist', {
        waitConfirmations: hre.network.live ? 12 : 1,
        from: deployer,
        log: true,
        args: deployArgs,
    });

    if (hre.network.live || hre.network.tags['rinkeby']) {
        try {
            const oracle = await deployments.get('OracleMock');
            const mixologist = await deployments.get('Mixologist');
            await hre.run('verify', { address: oracle.address });
            await hre.run('verify', { address: mixologist.address, constructorArgsParams: deployArgs });
        } catch (err) {
            console.log(err);
        }
    }
};
export default func;
func.tags = ['Mixologist', 'OracleMock'];
func.dependencies = ['TapiocaBar'];