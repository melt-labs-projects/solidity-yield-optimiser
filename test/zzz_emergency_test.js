const FarmOptimiser = artifacts.require('Optimiser');
const FarmCompounder = artifacts.require('PancakeswapCompounder');
const DelegateCompounder = artifacts.require('DelegateCompounder');
const FarmGate = artifacts.require('Gate');
const Token = artifacts.require('Token');
const LPToken = artifacts.require('LPToken');
const Native = artifacts.require('WETH');
const Router = artifacts.require('DummyRouter');
const MasterChef = artifacts.require('DummyPancakeswapFarm');
const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');


// Helper for converting to wei
const toWei = (ether) => { return web3.utils.toWei(ether.toString(), 'ether'); }

// Helper for converting from wei
const fromWei = (wei) => { return web3.utils.fromWei(wei); }


contract('Emergency Tests', accounts => {

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
        token0 = await Token.new(TenBillion)
        token1 = await Token.new(TenBillion)
        lp = await LPToken.new(TenBillion, token0.address, token1.address)
        native = await Native.new(TenBillion);

        // Define our dummy contracts
        plantation = await MasterChef.new([lp.address, lp.address], cake.address, false)
        router = await Router.new(lp.address, 1)
        otherRouter = await Router.new(lp.address, 1)

        // Define our contracts for testing
        optimiser = await FarmOptimiser.new(rwt.address, vault, toWei(50))
        delegate = await DelegateCompounder.new()
        compounder = await FarmCompounder.new(optimiser.address, plantation.address, rwt.address, vault, native.address, delegate.address)
        gate = await FarmGate.new(optimiser.address)

        // Transfer some rewards to the farm contracts
        await cake.transfer(plantation.address, OneBillion, { from: owner })
        await rwt.transfer(optimiser.address, OneBillion, { from: owner })

        // Send some lp funds to users
        await lp.transfer(accountA, toWei(100), { from: owner })
        await token0.transfer(accountA, toWei(100), { from: owner })
        await token1.transfer(accountA, toWei(100), { from: owner })
        await rwt.transfer(accountA, toWei(100), { from: owner })
        await cake.transfer(accountA, toWei(100), { from: owner })

        await lp.transfer(accountB, toWei(100), { from: owner })
        await token0.transfer(accountB, toWei(100), { from: owner })
        await token1.transfer(accountB, toWei(100), { from: owner })
        await rwt.transfer(accountB, toWei(100), { from: owner })
        await cake.transfer(accountB, toWei(100), { from: owner })

        // Allow farm to use lp funds
        await token0.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await token1.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await lp.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await rwt.increaseAllowance(gate.address, TenBillion, { from: accountA });
        await cake.increaseAllowance(gate.address, TenBillion, { from: accountA });

        await token0.increaseAllowance(gate.address, TenBillion, { from: accountB });
        await token1.increaseAllowance(gate.address, TenBillion, { from: accountB });
        await lp.increaseAllowance(gate.address, TenBillion, { from: accountB });
        await rwt.increaseAllowance(gate.address, TenBillion, { from: accountB });
        await cake.increaseAllowance(gate.address, TenBillion, { from: accountB });

        await lp.increaseAllowance(optimiser.address, TenBillion, { from: accountA });

        // Send funds to the router for swapping and liquidity
        await cake.transfer(router.address, OneBillion, { from: owner })
        await rwt.transfer(router.address, OneBillion, { from: owner })
        await lp.transfer(router.address, OneBillion, { from: owner })
        await token0.transfer(router.address, OneBillion, { from: owner })
        await token1.transfer(router.address, OneBillion, { from: owner })

        await cake.transfer(otherRouter.address, OneBillion, { from: owner })
        await token0.transfer(otherRouter.address, OneBillion, { from: owner })
        await token1.transfer(otherRouter.address, OneBillion, { from: owner })

        // Enable farm 0 in compounder
        await compounder.enableFarm(
            0, 
            [true, true, false],
            [lp.address, cake.address, token0.address, token1.address],
            [100, 100, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [otherRouter.address, router.address],
                [cake.address, token0.address, token1.address],
                [token1.address, rwt.address]
            ],
            router.address    
        )

        // Add compounder to optimiser
        await optimiser.addCompounder(compounder.address)

        // Enable farm 0 1 in optimiser
        await optimiser.enableFarm(0, 0, lp.address, 0, 0, 0)

        // Enable farm 1 in compounder
        await compounder.enableFarm(
            1, 
            [true, true, false],
            [lp.address, cake.address, token0.address, token1.address],
            [100, 100, 0],
            [cake.address, token0.address],
            [cake.address, token1.address],
            [
                [otherRouter.address, router.address],
                [cake.address, token0.address, token1.address],
                [token1.address, rwt.address]
            ],
            router.address    
        )

        // Enable farm 0 0 in optimiser
        await optimiser.enableFarm(0, 1, lp.address, 0, 0, 0)

    });

    const depositOneToken = async (sid, pid, amount, from) => {
        await gate.deposit(
            1, sid, pid, 
            amount, 
            [
                [router.address, otherRouter.address], 
                [token0.address, cake.address], [cake.address, token1.address]
            ], 
            [],
            router.address,
            { from: from }
        )
    }

    it('should withdraw during emergency', async () => {

        // Users deposit funds (potentially mutliple times)
        await depositOneToken(0, 0, toWei(1), accountA)
        await depositOneToken(0, 0, toWei(1), accountB)
        await depositOneToken(0, 0, toWei(1), accountB)

        await depositOneToken(0, 1, toWei(1), accountA)
        await depositOneToken(0, 1, toWei(1), accountB)

        // Emergency is triggered
        // Set the masterchef contract to revert on deposit and withdraw so that
        // we know only emergency withdraw is being used.
        await plantation.setEmergency(true) 
        await compounder.triggerEmergency()

        let userAmountInitial0B = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountB)))
        let userAmountInitial1B = parseFloat(fromWei(await optimiser.getUserAmount(0, 1, accountB)))

        // Users are able to withdraw (potentially multiple times)
        let userAmountA = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountA)))
        await optimiser.withdraw(0, 0, toWei(userAmountA / 2), {from: accountA})
        await optimiser.withdraw(0, 0, toWei(userAmountA / 2), {from: accountA})

        userAmountA = parseFloat(fromWei(await optimiser.getUserAmount(0, 1, accountA)))
        await optimiser.withdraw(0, 1, toWei(userAmountA), {from: accountA})

        let userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountB)))
        assert.equal(userAmountB, userAmountInitial0B);
        await optimiser.withdraw(0, 0, toWei(userAmountB / 4), {from: accountB})
        userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountB)))
        await optimiser.withdraw(0, 0, toWei(userAmountB / 4), {from: accountB})
        userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountB)))
        await optimiser.withdraw(0, 0, toWei(userAmountB / 4), {from: accountB})
        userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, 0, accountB)))
        await optimiser.withdraw(0, 0, toWei(userAmountB), {from: accountB})

        userAmountB = parseFloat(fromWei(await optimiser.getUserAmount(0, 1, accountB)))
        assert.equal(userAmountB, userAmountInitial1B);
        await optimiser.withdraw(0, 1, toWei(userAmountB), {from: accountB})
        
        // Cannot deposit during emergency
        expectRevert.unspecified(optimiser.deposit(0, 0, toWei(10), {from: accountA}))

    });


})

