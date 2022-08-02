const FarmOptimiser = artifacts.require('Optimiser');
const FarmCompounder = artifacts.require('PancakeswapCompounder');
const DelegateCompounder = artifacts.require('DelegateCompounder');
const FarmGate = artifacts.require('Gate');
const Token = artifacts.require('Token');
const Native = artifacts.require('WETH');
const Router = artifacts.require('DummyRouter');
const MasterChef = artifacts.require('DummyPancakeswapFarm');
const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');
const Web3 = require('web3')

// Helper for retrieving the blockNumber
const getBlockNumber = async () => {
    return await web3.eth.getBlockNumber();
}

// Helper for converting to wei
const toWei = (ether) => { return web3.utils.toWei(ether.toString(), 'ether'); }

// Helper for converting from wei
const fromWei = (wei) => { return web3.utils.fromWei(wei); }


contract('Single Token Basic Tests', accounts => {

    let optimiser;
    let compounder;
    let gate;
    let plantation;

    // Tokens
    let cake;
    let rwt;
    let lp;
    let token0;
    let token1;

    // Define named accounts
    let owner = accounts[0]
    let vault = accounts[1]
    let accountA = accounts[2]
    let accountB = accounts[3]

    before(async () => {
        
        // Some useful amounts
        let TenBillion = toWei(10000000000)
        let OneBillion = toWei(1000000000)

        // Define some tokens
        cake = await Token.new(TenBillion)
        rwt = await Token.new(TenBillion)
        lp = await Token.new(TenBillion)
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([cake.address], cake.address, false)
        router = await Router.new(lp.address, 1)

        // Define our contracts for testing
        optimiser = await FarmOptimiser.new(rwt.address, vault, toWei(50))
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(optimiser.address, plantation.address, rwt.address, vault, native.address, delegate.address)
        gate = await FarmGate.new(optimiser.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })
        await rwt.transfer(optimiser.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await cake.transfer(accountA, toWei(100), { from: owner })
        await cake.transfer(accountB, toWei(100), { from: owner })

        // Allow farm to use lp funds
        await cake.increaseAllowance(optimiser.address, TenBillion, { from: accountA });
        await cake.increaseAllowance(optimiser.address, TenBillion, { from: accountB });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

    });

    it('should enable new farm', async () => {

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [false, false, false],
            [cake.address, cake.address],
            [0, 0, 0],
            [],
            [],
            [
                [router.address],
                [cake.address, rwt.address]
            ],
            router.address
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 0, cake.address, 2, 0, 0)

        assert.equal(await compounder.isEnabled(0), true)
        assert.equal(await optimiser.isEnabled(0, 0), true)
        assert.equal(await optimiser.compounderCount(), 1)
        assert.equal(await optimiser.totalAllocPoints(), 2)
    });

    it('should deposit', async () => {
        await optimiser.deposit(0, 0, toWei(1), {from: accountA})

    });


})