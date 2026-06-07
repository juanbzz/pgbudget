# Zero-Sum Budgeting with Double-Entry Accounting

## Introduction
This specification explains how to implement zero-sum budgeting (like YNAB) using double-entry accounting principles. Zero-sum budgeting means giving every dollar a job, where total income equals total allocated funds.

> **Note on layering:** This document describes the *budgeting layer's*
> conceptual model. In pgbudget the generic `ledger` engine is typeless —
> accounts are just containers with debit/credit counters. The account
> "types" and balance directions below (asset/liability/equity,
> debit/credit normal balances) are meaning that the `budget` layer
> assigns on top of the engine, not columns stored in the ledger itself.

## Account Types

| Budget Concept | Accounting Type | Internal Behavior | Normal Balance |
|----------------|-----------------|-------------------|----------------|
| Bank Accounts  | Asset           | Asset-like        | Debit          |
| Credit Cards   | Liability       | Liability-like    | Credit         |
| Income         | Equity          | Liability-like    | Credit         |
| Budget Categories | Equity       | Liability-like    | Credit         |

### Key Insight
While traditional accounting has five account types (Asset, Liability, Equity, Revenue, Expenses), they all ultimately behave as either "asset-like" (debit increases, credit decreases) or "liability-like" (credit increases, debit decreases).

## Core Transactions

### 1. Receiving Income
```
Debit: Bank Account (Asset) +$1000
Credit: Income (Equity) +$1000
```
*Effect: Increases your bank balance and creates unallocated funds*

### 2. Budgeting Money
```
Debit: Income (Equity) -$200
Credit: Groceries (Equity) +$200
```
*Effect: Decreases unallocated money and increases category allocation*

### 3. Spending Money
```
Debit: Groceries (Equity) -$50
Credit: Bank Account (Asset) -$50
```
*Effect: Decreases both category balance and bank balance*

### 4. Credit Card Spending
```
Debit: Groceries (Equity) -$75
Credit: Credit Card (Liability) +$75
```
*Effect: Decreases category balance and increases credit card debt*

### 5. Paying Credit Card
```
Debit: Credit Card (Liability) -$75
Credit: Bank Account (Asset) -$75
```
*Effect: Decreases both credit card debt and bank balance*

## Why This Works

1. **Balance Sheet Integrity**: The accounting equation (Assets = Liabilities + Equity) always remains balanced
2. **Category Tracking**: Budget categories act as mini-equity accounts that track your financial intentions
3. **Debit/Credit Logic**: All transactions follow proper double-entry principles
4. **Financial Clarity**: Every dollar has a clear status: where it is (assets/liabilities) and what it's for (categories)

## Implementation Tips

1. **Start Simple**: Begin with just three accounts: Bank Account, Income, and one Budget Category
2. **Income is Equity**: Treat Income as unallocated equity rather than revenue
3. **Categories are Equity**: Categories represent portions of your wealth you've assigned to specific purposes
4. **Database Design**: Keep account semantics (asset, liability, equity) and their balance direction in the budgeting layer — the generic ledger engine stores only raw debit/credit counters and assigns no type
5. **Reports**: Budget reports show category balances; financial reports show actual account balances

## Rules to Remember

- Every transaction affects at least two accounts
- Total debits must equal total credits in every transaction
- Budget until Income equals zero (hence "zero-sum")
- Never spend from a category with insufficient balance