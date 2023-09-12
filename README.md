# Spark Conduits

Conduits required to connect the Maker allocation system to Spark. There will be two versions. One that is for local instances on Ethereum (and Goerli) and another for chains that require a bridge.

The general idea of the Spark Conduit (both versions) is to allow allocators to provision asset(s) to the market via the `deposit()` function which is standard to all Conduits. The funds will then be forwarded to the pool and the depositor credited.

Conversely if the allocator wants to withdraw funds they can call `withdraw()` provided there is idle liquidity available. If not they will need to signal their intent for withdrawal which will increase the interest rate on the pool to encourage third party deposits and repayments of loans.

Signaling intent to withdraw is done by the allocator calling `requestFunds()` and specifying how much they are looking to withdraw. The reason it is done this way instead of using a kink on the pool is to avoid thrashing interest rates on the pool. IE there is 10m idle liquidity and allocator wants to withdraw 100m. With the interest rate kink the process would be withdraw 10m, interest rates max out, 3rd party depositor/repay occurs of ~10m and the rates go back down. This process would repeat 10x which is a bad experience for users. Instead the allocator signals the intent to withdraw 100m and the pool will set the interest rates accordingly and only bringing the rate back down when the allocator completes the full withdraw (or partial ones along the way).

Allocators can cancel withdrawal intents by calling `cancelFundRequest()`.

Calling `requestFunds()` twice will override the previous fund request instead of add to it.

## SparkConduit

`SparkConduit` is used for a local instance of Spark Lend. All dependency values are immediately accessible. The contract is upgradable to facilitate changes to logic if needed.

### Configuration

`roles` - The roles contract to perform operator authentication.
`registry` - Maps ilks to allocation buffer.
`subsidySpread` - The delta between the Base Rate and the Subsidy Rate. [RAY]

![WithdrawSpark](https://github.com/marsfoundation/spark-conduits/assets/44272939/a3e15eca-b8f8-42e8-bd18-0bc964c3efc7)
![DepositSpark](https://github.com/marsfoundation/spark-conduits/assets/44272939/ae246844-94de-4720-99d0-7ee8f7683a80)
