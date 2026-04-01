package main

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/j0lvera/pgbudget/testutils/pgcontainer"
	"github.com/jackc/pgx/v5"
	is_ "github.com/matryer/is"
	"github.com/rs/zerolog"
)

var (
	testDSN string
	log     zerolog.Logger
)

func TestMain(m *testing.M) {
	// Setup logging
	log = zerolog.New(os.Stdout).With().Timestamp().Logger()

	// Create a context with timeout for setup
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Configure and start the PostgreSQL container
	cfg := pgcontainer.NewConfig()
	cfg.WithLogger(&log).WithMigrationsPath("migrations") // Path relative to project root (src)

	pgContainer := pgcontainer.NewPgContainer(cfg)
	output, err := pgContainer.Start(ctx)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to start PostgreSQL container")
	}

	// Store the DSN for tests to use
	testDSN = output.DSN()

	// Run the tests
	exitCode := m.Run()

	// Exit with the same code as the tests
	os.Exit(exitCode)
}

// setTestUserContext sets the user context for the database session
// This simulates what the Go microservice would do for each authenticated request
func setTestUserContext(ctx context.Context, conn *pgx.Conn, userID string) error {
	// Set the session variable to persist for the entire connection
	_, err := conn.Exec(ctx, "SELECT set_config('app.current_user_id', $1, false)", userID)
	return err
}

// verifyTestUserContext verifies that the user context is set correctly
func verifyTestUserContext(ctx context.Context, conn *pgx.Conn, expectedUserID string) error {
	var userFromSession string
	err := conn.QueryRow(ctx, `SELECT utils.get_user()`).Scan(&userFromSession)
	if err != nil {
		return fmt.Errorf("failed to get user from utils.get_user(): %w", err)
	}
	if userFromSession != expectedUserID {
		return fmt.Errorf("expected user %q, got %q", expectedUserID, userFromSession)
	}
	return nil
}

func TestLedger(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "ledger_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	t.Run("SchemaExists", func(t *testing.T) {
		is := is_.New(t)

		var exists bool
		err := conn.QueryRow(ctx, `
			select exists (
				select 1 from information_schema.schemata where schema_name = 'ledger'
			)
		`).Scan(&exists)
		is.NoErr(err)
		is.True(exists)
	})

	// create a ledger for subsequent tests
	var ledgerUUID string

	t.Run("CreateLedger", func(t *testing.T) {
		is := is_.New(t)

		err := conn.QueryRow(ctx, `select ledger.create_ledger('Test Ledger')`).Scan(&ledgerUUID)
		is.NoErr(err)
		is.True(len(ledgerUUID) == 8)
	})

	t.Run("CreateLedgerWithDescription", func(t *testing.T) {
		is := is_.New(t)

		var uuid string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Described Ledger', 'A test ledger')`).Scan(&uuid)
		is.NoErr(err)

		var desc *string
		err = conn.QueryRow(ctx, `select description from data.ledgers where uuid = $1`, uuid).Scan(&desc)
		is.NoErr(err)
		is.True(desc != nil)
		is.Equal(*desc, "A test ledger")
	})

	t.Run("CreateLedgerRejectsEmptyName", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_ledger('')`)
		is.True(err != nil)

		_, err = conn.Exec(ctx, `select ledger.create_ledger('   ')`)
		is.True(err != nil)
	})

	// create accounts for transaction tests
	var checkingUUID, savingsUUID, visaUUID, incomeUUID string

	t.Run("CreateAccount", func(t *testing.T) {
		is := is_.New(t)

		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		is.True(len(checkingUUID) == 8)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings', 'asset')`, ledgerUUID).Scan(&savingsUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Visa', 'liability')`, ledgerUUID).Scan(&visaUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&incomeUUID)
		is.NoErr(err)
	})

	t.Run("CreateAccountValidatesType", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_account($1, 'Bad', 'revenue')`, ledgerUUID)
		is.True(err != nil)

		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Bad', 'expense')`, ledgerUUID)
		is.True(err != nil)
	})

	t.Run("CreateAccountRejectsEmptyName", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_account($1, '', 'asset')`, ledgerUUID)
		is.True(err != nil)
	})

	t.Run("CreateAccountRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_account('nonexistent', 'Checking', 'asset')`)
		is.True(err != nil)
	})

	// post_transaction tests
	t.Run("PostTransaction", func(t *testing.T) {
		is := is_.New(t)

		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100000, '2025-03-15', 'Paycheck')
		`, ledgerUUID, checkingUUID, incomeUUID).Scan(&txUUID)
		is.NoErr(err)
		is.True(len(txUUID) == 8)
	})

	t.Run("PostTransactionUpdatesCounters", func(t *testing.T) {
		is := is_.New(t)

		// checking was debited 100000
		var debits, credits int64
		err := conn.QueryRow(ctx, `
			select debits_total, credits_total from data.accounts where uuid = $1
		`, checkingUUID).Scan(&debits, &credits)
		is.NoErr(err)
		is.Equal(debits, int64(100000))
		is.Equal(credits, int64(0))

		// income was credited 100000
		err = conn.QueryRow(ctx, `
			select debits_total, credits_total from data.accounts where uuid = $1
		`, incomeUUID).Scan(&debits, &credits)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(100000))
	})

	t.Run("PostTransactionCreatesBalanceHistory", func(t *testing.T) {
		is := is_.New(t)

		// should have balance history entries for both accounts
		var count int
		err := conn.QueryRow(ctx, `
			select count(*) from data.balances
			where user_data = $1
		`, testUserID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 2) // one for debit account, one for credit account
	})

	t.Run("PostTransactionBalanceHistoryIsCorrect", func(t *testing.T) {
		is := is_.New(t)

		// checking: debits_total=100000, credits_total=0
		var debits, credits int64
		err := conn.QueryRow(ctx, `
			select debits_total, credits_total from data.balances
			where account_id = (select id from data.accounts where uuid = $1)
			order by transaction_id desc limit 1
		`, checkingUUID).Scan(&debits, &credits)
		is.NoErr(err)
		is.Equal(debits, int64(100000))
		is.Equal(credits, int64(0))
	})

	t.Run("PostMultipleTransactions", func(t *testing.T) {
		is := is_.New(t)

		// spend from checking to visa (simulating a payment)
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 25000, '2025-03-16', 'Visa payment')
		`, ledgerUUID, visaUUID, checkingUUID).Scan(&txUUID)
		is.NoErr(err)

		// checking: debited 100000 (paycheck), credited 25000 (visa payment)
		var debits, credits int64
		err = conn.QueryRow(ctx, `
			select debits_total, credits_total from data.accounts where uuid = $1
		`, checkingUUID).Scan(&debits, &credits)
		is.NoErr(err)
		is.Equal(debits, int64(100000))
		is.Equal(credits, int64(25000))

		// visa: debited 25000
		err = conn.QueryRow(ctx, `
			select debits_total, credits_total from data.accounts where uuid = $1
		`, visaUUID).Scan(&debits, &credits)
		is.NoErr(err)
		is.Equal(debits, int64(25000))
		is.Equal(credits, int64(0))
	})

	t.Run("BalanceFromCounters", func(t *testing.T) {
		is := is_.New(t)

		// checking: asset_like → balance = debits - credits = 100000 - 25000 = 75000
		var balance int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(75000))

		// income: equity → balance = credits - debits = 100000 - 0 = 100000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, incomeUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(100000))

		// visa: liability_like → balance = credits - debits = 0 - 25000 = -25000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, visaUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(-25000))
	})

	t.Run("PostTransactionRejectsZeroAmount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 0, '2025-03-15', 'Zero')
		`, ledgerUUID, checkingUUID, incomeUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectsNegativeAmount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, -100, '2025-03-15', 'Negative')
		`, ledgerUUID, checkingUUID, incomeUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectsSameAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $2, 100, '2025-03-15', 'Self')
		`, ledgerUUID, checkingUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectsInvalidDebit", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, 'nonexistent', $2, 100, '2025-03-15', 'Bad')
		`, ledgerUUID, incomeUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectsInvalidCredit", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, 'nonexistent', 100, '2025-03-15', 'Bad')
		`, ledgerUUID, checkingUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction('nonexistent', $1, $2, 100, '2025-03-15', 'Bad')
		`, checkingUUID, incomeUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionDefaultDate", func(t *testing.T) {
		is := is_.New(t)

		// omit the date parameter to use the default (current_date)
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 500)
		`, ledgerUUID, checkingUUID, incomeUUID).Scan(&txUUID)
		is.NoErr(err)

		var txDate time.Time
		err = conn.QueryRow(ctx, `select date from data.transactions where uuid = $1`, txUUID).Scan(&txDate)
		is.NoErr(err)

		now := time.Now().UTC()
		is.Equal(txDate.Year(), now.Year())
		is.Equal(txDate.Month(), now.Month())
		is.Equal(txDate.Day(), now.Day())
	})

	// --- void and correct tests ---
	// set up a fresh ledger for void/correct tests to avoid interference
	var voidLedgerUUID, voidCheckingUUID, voidIncomeUUID string

	t.Run("VoidSetup", func(t *testing.T) {
		is := is_.New(t)

		err := conn.QueryRow(ctx, `select ledger.create_ledger('Void Test Ledger')`).Scan(&voidLedgerUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, voidLedgerUUID).Scan(&voidCheckingUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, voidLedgerUUID).Scan(&voidIncomeUUID)
		is.NoErr(err)
	})

	t.Run("VoidCreatesReversal", func(t *testing.T) {
		is := is_.New(t)

		// post a transaction
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 50000, '2025-03-15', 'Original payment')
		`, voidLedgerUUID, voidCheckingUUID, voidIncomeUUID).Scan(&txUUID)
		is.NoErr(err)

		// verify balance before void
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, voidCheckingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(50000))

		// void it
		var reversalUUID string
		err = conn.QueryRow(ctx, `select ledger.void($1, 'Wrong amount')`, txUUID).Scan(&reversalUUID)
		is.NoErr(err)
		is.True(len(reversalUUID) == 8)

		// balance should be restored to 0
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, voidCheckingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(0))
	})

	t.Run("VoidCreatesTransactionLog", func(t *testing.T) {
		is := is_.New(t)

		var mutationType, reason string
		err := conn.QueryRow(ctx, `
			select mutation_type, reason from data.transaction_log
			where user_data = $1
			order by created_at desc limit 1
		`, testUserID).Scan(&mutationType, &reason)
		is.NoErr(err)
		is.Equal(mutationType, "deletion")
		is.Equal(reason, "Wrong amount")
	})

	t.Run("VoidRejectsInvalidTransaction", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.void('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("CorrectChangesAmount", func(t *testing.T) {
		is := is_.New(t)

		// post a transaction
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-20', 'Groceries')
		`, voidLedgerUUID, voidCheckingUUID, voidIncomeUUID).Scan(&txUUID)
		is.NoErr(err)

		// correct amount from 10000 to 15000
		var correctionUUID string
		err = conn.QueryRow(ctx, `
			select ledger.correct($1, p_amount := 15000, p_reason := 'Was $100 not $150')
		`, txUUID).Scan(&correctionUUID)
		is.NoErr(err)
		is.True(len(correctionUUID) == 8)
		is.True(correctionUUID != txUUID) // should be a new transaction

		// verify corrected transaction has new amount
		var amount int64
		err = conn.QueryRow(ctx, `select amount from data.transactions where uuid = $1`, correctionUUID).Scan(&amount)
		is.NoErr(err)
		is.Equal(amount, int64(15000))
	})

	t.Run("CorrectPreservesUnchangedFields", func(t *testing.T) {
		is := is_.New(t)

		// post a transaction
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 20000, '2025-04-01', 'Rent')
		`, voidLedgerUUID, voidCheckingUUID, voidIncomeUUID).Scan(&txUUID)
		is.NoErr(err)

		// correct only the description
		var correctionUUID string
		err = conn.QueryRow(ctx, `
			select ledger.correct($1, p_description := 'April rent')
		`, txUUID).Scan(&correctionUUID)
		is.NoErr(err)

		// verify amount and date carried over, description changed
		var amount int64
		var desc string
		var txDate time.Time
		err = conn.QueryRow(ctx, `
			select amount, description, date from data.transactions where uuid = $1
		`, correctionUUID).Scan(&amount, &desc, &txDate)
		is.NoErr(err)
		is.Equal(amount, int64(20000))           // unchanged
		is.Equal(desc, "April rent")              // changed
		is.Equal(txDate.Day(), 1)                 // unchanged
	})

	t.Run("CorrectCreatesTransactionLog", func(t *testing.T) {
		is := is_.New(t)

		var mutationType string
		var reversalID, correctionID *int64
		err := conn.QueryRow(ctx, `
			select mutation_type, reversal_transaction_id, correction_transaction_id
			from data.transaction_log
			where user_data = $1 and mutation_type = 'correction'
			order by created_at desc limit 1
		`, testUserID).Scan(&mutationType, &reversalID, &correctionID)
		is.NoErr(err)
		is.Equal(mutationType, "correction")
		is.True(reversalID != nil)    // reversal was created
		is.True(correctionID != nil)  // correction was created
	})

	t.Run("CorrectRejectsInvalidTransaction", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.correct('nonexistent', p_amount := 100)`)
		is.True(err != nil)
	})

	t.Run("CorrectBalancesAreCorrect", func(t *testing.T) {
		is := is_.New(t)

		// fresh ledger for clean balance check
		var freshLedger, freshChecking, freshIncome string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Balance Correct Test')`).Scan(&freshLedger)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, freshLedger).Scan(&freshChecking)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, freshLedger).Scan(&freshIncome)
		is.NoErr(err)

		// post 10000
		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-15', 'Original')
		`, freshLedger, freshChecking, freshIncome).Scan(&txUUID)
		is.NoErr(err)

		// correct to 15000 — reversal (-10000) + new (+15000) = net 15000
		_, err = conn.Exec(ctx, `select ledger.correct($1, p_amount := 15000)`, txUUID)
		is.NoErr(err)

		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, freshChecking).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(15000)) // net: 10000 - 10000 + 15000
	})
}

func TestLedgerQueries(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "ledger_queries_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	// set up ledger with accounts and transactions
	var ledgerUUID, checkingUUID, savingsUUID, revenueUUID string

	err = conn.QueryRow(ctx, `select ledger.create_ledger('Query Test Ledger')`).Scan(&ledgerUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings', 'asset')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	// post some transactions
	// 1. income: debit checking 100000, credit revenue
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 100000, '2025-03-01', 'Paycheck')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)
	// 2. transfer: debit savings 30000, credit checking (move to savings)
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 30000, '2025-03-05', 'To savings')`, ledgerUUID, savingsUUID, checkingUUID)
	is.NoErr(err)
	// 3. another income: debit checking 50000, credit revenue
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 50000, '2025-03-15', 'Freelance')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)

	t.Run("GetBalance", func(t *testing.T) {
		is := is_.New(t)

		// checking: debits 150000, credits 30000 → balance 120000
		var balance int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(120000))

		// savings: debits 30000, credits 0 → balance 30000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, savingsUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(30000))

		// revenue: equity → credits 150000, debits 0 → balance 150000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, revenueUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(150000))
	})

	t.Run("GetBalanceRejectsInvalidAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.get_balance('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("GetBalances", func(t *testing.T) {
		is := is_.New(t)

		type accountBalance struct {
			UUID    string
			Name    string
			Type    string
			Balance int64
		}

		rows, err := conn.Query(ctx, `select * from ledger.get_balances($1)`, ledgerUUID)
		is.NoErr(err)
		defer rows.Close()

		var balances []accountBalance
		for rows.Next() {
			var ab accountBalance
			err := rows.Scan(&ab.UUID, &ab.Name, &ab.Type, &ab.Balance)
			is.NoErr(err)
			balances = append(balances, ab)
		}
		is.NoErr(rows.Err())

		// should have at least our 3 accounts (plus any default accounts from trigger)
		is.True(len(balances) >= 3)

		// find our accounts and verify balances
		var foundChecking, foundSavings, foundRevenue bool
		for _, ab := range balances {
			switch ab.UUID {
			case checkingUUID:
				is.Equal(ab.Balance, int64(120000))
				is.Equal(ab.Type, "asset")
				foundChecking = true
			case savingsUUID:
				is.Equal(ab.Balance, int64(30000))
				is.Equal(ab.Type, "asset")
				foundSavings = true
			case revenueUUID:
				is.Equal(ab.Balance, int64(150000))
				is.Equal(ab.Type, "equity")
				foundRevenue = true
			}
		}
		is.True(foundChecking)
		is.True(foundSavings)
		is.True(foundRevenue)
	})

	t.Run("GetBalancesRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select * from ledger.get_balances('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("GetHistory", func(t *testing.T) {
		is := is_.New(t)

		type historyRow struct {
			TxUUID         string
			Date           time.Time
			Description    string
			Counterparty   string
			Amount         int64
			Direction      string
			RunningBalance int64
		}

		rows, err := conn.Query(ctx, `select * from ledger.get_history($1)`, checkingUUID)
		is.NoErr(err)
		defer rows.Close()

		var history []historyRow
		for rows.Next() {
			var h historyRow
			err := rows.Scan(&h.TxUUID, &h.Date, &h.Description, &h.Counterparty, &h.Amount, &h.Direction, &h.RunningBalance)
			is.NoErr(err)
			history = append(history, h)
		}
		is.NoErr(rows.Err())

		// checking has 3 transactions, newest first
		is.Equal(len(history), 3)

		// most recent: Freelance (debit checking 50000)
		is.Equal(history[0].Description, "Freelance")
		is.Equal(history[0].Amount, int64(50000))
		is.Equal(history[0].Direction, "debit")
		is.Equal(history[0].RunningBalance, int64(120000)) // 100000 - 30000 + 50000

		// middle: To savings (credit checking 30000)
		is.Equal(history[1].Description, "To savings")
		is.Equal(history[1].Amount, int64(30000))
		is.Equal(history[1].Direction, "credit")
		is.Equal(history[1].RunningBalance, int64(70000)) // 100000 - 30000

		// oldest: Paycheck (debit checking 100000)
		is.Equal(history[2].Description, "Paycheck")
		is.Equal(history[2].Amount, int64(100000))
		is.Equal(history[2].Direction, "debit")
		is.Equal(history[2].RunningBalance, int64(100000))
	})

	t.Run("GetHistoryCounterparty", func(t *testing.T) {
		is := is_.New(t)

		rows, err := conn.Query(ctx, `select counterparty from ledger.get_history($1)`, checkingUUID)
		is.NoErr(err)
		defer rows.Close()

		var counterparties []string
		for rows.Next() {
			var cp string
			err := rows.Scan(&cp)
			is.NoErr(err)
			counterparties = append(counterparties, cp)
		}
		is.NoErr(rows.Err())

		// counterparty is the other account in each transaction
		is.Equal(counterparties[0], "Revenue")  // Freelance: debit checking, credit revenue
		is.Equal(counterparties[1], "Savings")   // To savings: debit savings, credit checking
		is.Equal(counterparties[2], "Revenue")   // Paycheck: debit checking, credit revenue
	})

	t.Run("GetHistoryRejectsInvalidAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select * from ledger.get_history('nonexistent')`)
		is.True(err != nil)
	})
}

func TestLinkedTransfers(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "linked_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Linked Test')`).Scan(&ledgerUUID)
	is.NoErr(err)

	// get the auto-created clearing account
	var clearingUUID string
	err = conn.QueryRow(ctx, `
		select account_uuid from ledger.get_accounts($1, true)
		where visibility = 'internal' and account_name = 'clearing'
	`, ledgerUUID).Scan(&clearingUUID)
	is.NoErr(err)

	// create user accounts
	var checkingUUID, visaUUID, revenueUUID string
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Visa', 'liability')`, ledgerUUID).Scan(&visaUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	// seed checking with balance
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 500000, '2025-03-01', 'Seed')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)

	t.Run("ClearingAccountAutoCreated", func(t *testing.T) {
		is := is_.New(t)

		is.True(len(clearingUUID) == 8)

		// clearing account should NOT show in default get_accounts
		var count int
		err := conn.QueryRow(ctx, `
			select count(*) from ledger.get_accounts($1)
			where account_name = 'clearing'
		`, ledgerUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 0) // hidden by default

		// but should show with include_internal
		err = conn.QueryRow(ctx, `
			select count(*) from ledger.get_accounts($1, true)
			where account_name = 'clearing'
		`, ledgerUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 1)
	})

	t.Run("PostLinkedCreditCardPayment", func(t *testing.T) {
		is := is_.New(t)

		var uuids []string
		err := conn.QueryRow(ctx, `
			select ledger.post_linked($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 50000, "date": "2025-03-28", "description": "VISA PAYMENT"},
			{"debit": "%s", "credit": "%s", "amount": 50000, "date": "2025-03-30", "description": "PAYMENT RECEIVED"}
		]`, clearingUUID, checkingUUID, visaUUID, clearingUUID)).Scan(&uuids)
		is.NoErr(err)
		is.Equal(len(uuids), 2)

		// verify both share the same link_id
		var link1, link2 *int64
		err = conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuids[0]).Scan(&link1)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuids[1]).Scan(&link2)
		is.NoErr(err)
		is.True(link1 != nil)
		is.True(link2 != nil)
		is.Equal(*link1, *link2) // same link_id
	})

	t.Run("ClearingAccountNetsToZero", func(t *testing.T) {
		is := is_.New(t)

		var balance int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, clearingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(0)) // clearing always nets to zero
	})

	t.Run("GetHistoryResolvesCounterparty", func(t *testing.T) {
		is := is_.New(t)

		// checking history should show Visa as counterparty, not Clearing
		var counterparty string
		err := conn.QueryRow(ctx, `
			select counterparty from ledger.get_history($1)
			where description = 'VISA PAYMENT'
		`, checkingUUID).Scan(&counterparty)
		is.NoErr(err)
		is.Equal(counterparty, "Visa") // resolved through clearing

		// visa history should show Checking as counterparty
		err = conn.QueryRow(ctx, `
			select counterparty from ledger.get_history($1)
			where description = 'PAYMENT RECEIVED'
		`, visaUUID).Scan(&counterparty)
		is.NoErr(err)
		is.Equal(counterparty, "Checking") // resolved through clearing
	})

	t.Run("GetHistoryShowsCorrectDatesPerSide", func(t *testing.T) {
		is := is_.New(t)

		// checking should show March 28
		var checkingDate time.Time
		err := conn.QueryRow(ctx, `
			select date from ledger.get_history($1)
			where description = 'VISA PAYMENT'
		`, checkingUUID).Scan(&checkingDate)
		is.NoErr(err)
		is.Equal(checkingDate.Day(), 28)

		// visa should show March 30
		var visaDate time.Time
		err = conn.QueryRow(ctx, `
			select date from ledger.get_history($1)
			where description = 'PAYMENT RECEIVED'
		`, visaUUID).Scan(&visaDate)
		is.NoErr(err)
		is.Equal(visaDate.Day(), 30)
	})

	t.Run("LinkedIsAtomic", func(t *testing.T) {
		is := is_.New(t)

		// second entry has invalid account — whole batch should fail
		_, err := conn.Exec(ctx, `
			select ledger.post_linked($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 1000, "description": "Good"},
			{"debit": "nonexistent", "credit": "%s", "amount": 1000, "description": "Bad"}
		]`, clearingUUID, checkingUUID, clearingUUID))
		is.True(err != nil)
	})

	t.Run("LinkedRequiresAtLeastTwo", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_linked($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 1000}
		]`, clearingUUID, checkingUUID))
		is.True(err != nil) // needs at least 2
	})

	t.Run("LinkedWithThreeLegs", func(t *testing.T) {
		is := is_.New(t)

		// split payment: checking pays $300, visa pays $200, total $500 to revenue
		var uuids []string
		err := conn.QueryRow(ctx, `
			select ledger.post_linked($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 30000, "date": "2025-04-01", "description": "Checking portion"},
			{"debit": "%s", "credit": "%s", "amount": 20000, "date": "2025-04-01", "description": "Visa portion"},
			{"debit": "%s", "credit": "%s", "amount": 50000, "date": "2025-04-01", "description": "Total to revenue"}
		]`, clearingUUID, checkingUUID, clearingUUID, visaUUID, revenueUUID, clearingUUID)).Scan(&uuids)
		is.NoErr(err)
		is.Equal(len(uuids), 3)

		// clearing still nets to zero (credited 30000+20000, debited 50000)
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, clearingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(0))
	})
}

func TestAccountClosing(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "closing_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID, checkingUUID, savingsUUID, revenueUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Closing Test')`).Scan(&ledgerUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings', 'asset')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	// seed some balance
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 100000, '2025-03-01', 'Seed')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)

	t.Run("CloseAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.close_account($1)`, savingsUUID)
		is.NoErr(err)

		var isClosed bool
		err = conn.QueryRow(ctx, `select is_closed from data.accounts where uuid = $1`, savingsUUID).Scan(&isClosed)
		is.NoErr(err)
		is.True(isClosed)
	})

	t.Run("PostTransactionRejectedOnClosedDebit", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 1000, '2025-03-02', 'Should fail')
		`, ledgerUUID, savingsUUID, revenueUUID)
		is.True(err != nil)
	})

	t.Run("PostTransactionRejectedOnClosedCredit", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 1000, '2025-03-02', 'Should fail')
		`, ledgerUUID, checkingUUID, savingsUUID)
		is.True(err != nil)
	})

	t.Run("ReserveRejectedOnClosedAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.reserve($1, $2, $3, 1000, 300)
		`, ledgerUUID, savingsUUID, revenueUUID)
		is.True(err != nil)
	})

	t.Run("CommitRejectedOnClosedAccount", func(t *testing.T) {
		is := is_.New(t)

		// reserve on open accounts first
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 5000, 300, '2025-03-03', 'Before close')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// close the checking account
		_, err = conn.Exec(ctx, `select ledger.close_account($1)`, checkingUUID)
		is.NoErr(err)

		// commit should fail
		_, err = conn.Exec(ctx, `select ledger.commit($1)`, txUUID)
		is.True(err != nil)

		// but release should work
		_, err = conn.Exec(ctx, `select ledger.release($1)`, txUUID)
		is.NoErr(err)
	})

	t.Run("VoidAllowedOnClosedAccount", func(t *testing.T) {
		is := is_.New(t)

		// we need a transaction on the now-closed checking account to void
		// use the seed transaction (posted before closing)
		var seedUUID string
		err := conn.QueryRow(ctx, `
			select uuid from data.transactions
			where description = 'Seed' and user_data = $1
			limit 1
		`, testUserID).Scan(&seedUUID)
		is.NoErr(err)

		// void should succeed even though checking is closed
		var reversalUUID string
		err = conn.QueryRow(ctx, `select ledger.void($1, 'Unwinding after close')`, seedUUID).Scan(&reversalUUID)
		is.NoErr(err)
		is.True(len(reversalUUID) == 8)
	})

	t.Run("CorrectRejectedOnClosedAccount", func(t *testing.T) {
		is := is_.New(t)

		// create a transaction between open accounts to try to correct into a closed one
		var openAcctUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Open Acct', 'asset')`, ledgerUUID).Scan(&openAcctUUID)
		is.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 1000, '2025-03-04', 'To correct')
		`, ledgerUUID, openAcctUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// try to correct the debit account to the closed savings — should fail
		_, err = conn.Exec(ctx, `select ledger.correct($1, p_debit_account_uuid := $2)`, txUUID, savingsUUID)
		is.True(err != nil)
	})

	t.Run("CloseAccountRejectsInvalidUUID", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.close_account('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("BatchRejectedOnClosedAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 100, "description": "Hits closed"}
		]`, savingsUUID, revenueUUID))
		is.True(err != nil)
	})
}

func TestLedgerCRUD(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "ledger_crud_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	t.Run("GetAccounts", func(t *testing.T) {
		is := is_.New(t)

		var ledgerUUID string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Get Accounts Test')`).Scan(&ledgerUUID)
		is.NoErr(err)

		// create accounts of different types
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Visa', 'liability')`, ledgerUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID)
		is.NoErr(err)

		type account struct {
			UUID        string
			Name        string
			Type        string
			Description *string
		}

		rows, err := conn.Query(ctx, `select account_uuid, account_name, account_type, description from ledger.get_accounts($1)`, ledgerUUID)
		is.NoErr(err)
		defer rows.Close()

		var accounts []account
		for rows.Next() {
			var a account
			err := rows.Scan(&a.UUID, &a.Name, &a.Type, &a.Description)
			is.NoErr(err)
			accounts = append(accounts, a)
		}
		is.NoErr(rows.Err())

		// should have our 3 + any default accounts from trigger
		is.True(len(accounts) >= 3)

		// verify our accounts are present
		names := make(map[string]string)
		for _, a := range accounts {
			names[a.Name] = a.Type
		}
		is.Equal(names["Checking"], "asset")
		is.Equal(names["Visa"], "liability")
		is.Equal(names["Revenue"], "equity")
	})

	t.Run("GetAccountsRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select * from ledger.get_accounts('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("DeleteLedger", func(t *testing.T) {
		is := is_.New(t)

		// create a ledger with accounts and transactions
		var ledgerUUID, checkingUUID, revenueUUID string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('To Delete')`).Scan(&ledgerUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000, '2025-03-01', 'Seed')`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)

		// delete it
		_, err = conn.Exec(ctx, `select ledger.delete_ledger($1)`, ledgerUUID)
		is.NoErr(err)

		// verify ledger is gone
		var count int
		err = conn.QueryRow(ctx, `select count(*) from data.ledgers where uuid = $1`, ledgerUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 0)

		// verify accounts are gone
		err = conn.QueryRow(ctx, `select count(*) from data.accounts where uuid = $1`, checkingUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 0)
	})

	t.Run("DeleteLedgerRejectsInvalidUUID", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.delete_ledger('nonexistent')`)
		is.True(err != nil)
	})

	t.Run("DeleteLedgerWithPendingHolds", func(t *testing.T) {
		is := is_.New(t)

		// create ledger with a pending hold
		var ledgerUUID, checkingUUID, revenueUUID string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Delete With Pending')`).Scan(&ledgerUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
		is.NoErr(err)

		// seed + reserve
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 5000, 300)`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)

		// delete should clean up pending too
		_, err = conn.Exec(ctx, `select ledger.delete_ledger($1)`, ledgerUUID)
		is.NoErr(err)

		// verify everything is gone
		var count int
		err = conn.QueryRow(ctx, `select count(*) from data.ledgers where uuid = $1`, ledgerUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 0)
	})

	t.Run("RebuildBalances", func(t *testing.T) {
		is := is_.New(t)

		// create ledger with transactions
		var ledgerUUID, checkingUUID, revenueUUID string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Rebuild Test')`).Scan(&ledgerUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 50000, '2025-03-01', 'First')`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 30000, '2025-03-15', 'Second')`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)

		// verify correct balance before rebuild
		var balanceBefore int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)
		is.Equal(balanceBefore, int64(80000))

		// manually corrupt the counters
		_, err = conn.Exec(ctx, `update data.accounts set debits_total = 0, credits_total = 0 where uuid = $1`, checkingUUID)
		is.NoErr(err)

		// verify balance is now wrong
		var corruptedBalance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&corruptedBalance)
		is.NoErr(err)
		is.Equal(corruptedBalance, int64(0)) // corrupted

		// rebuild
		_, err = conn.Exec(ctx, `select ledger.rebuild_balances($1)`, ledgerUUID)
		is.NoErr(err)

		// verify balance is restored
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceAfter, int64(80000)) // restored

		// verify balance history is correct
		var historyCount int
		err = conn.QueryRow(ctx, `
			select count(*) from data.balances
			where account_id = (select id from data.accounts where uuid = $1)
		`, checkingUUID).Scan(&historyCount)
		is.NoErr(err)
		is.Equal(historyCount, 2) // one per transaction
	})

	t.Run("RebuildBalancesRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.rebuild_balances('nonexistent')`)
		is.True(err != nil)
	})
}

func TestTwoPhaseTransfers(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "two_phase_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID, checkingUUID, revenueUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Two Phase Test')`).Scan(&ledgerUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	// seed with posted balance so we have something to work with
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 100000, '2025-03-01', 'Seed')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)

	t.Run("ReserveCreatesPendingTransaction", func(t *testing.T) {
		is := is_.New(t)

		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 25000, 300, '2025-03-15', 'Hold for payment')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)
		is.True(len(txUUID) == 8)

		// verify status is pending
		var status string
		err = conn.QueryRow(ctx, `select status from data.transactions where uuid = $1`, txUUID).Scan(&status)
		is.NoErr(err)
		is.Equal(status, "pending")

		// verify pending rows created
		var pendingCount int
		err = conn.QueryRow(ctx, `select count(*) from data.pending where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&pendingCount)
		is.NoErr(err)
		is.Equal(pendingCount, 2) // one per account

		// verify posted counters NOT updated (still at seed values)
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(100000)) // unchanged
	})

	t.Run("CommitSettlesPending", func(t *testing.T) {
		is := is_.New(t)

		// reserve
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 10000, 300, '2025-03-16', 'To commit')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// get balance before commit
		var balanceBefore int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)

		// commit
		var committedUUID string
		err = conn.QueryRow(ctx, `select ledger.commit($1)`, txUUID).Scan(&committedUUID)
		is.NoErr(err)
		is.Equal(committedUUID, txUUID)

		// verify status is posted
		var status string
		err = conn.QueryRow(ctx, `select status from data.transactions where uuid = $1`, txUUID).Scan(&status)
		is.NoErr(err)
		is.Equal(status, "posted")

		// verify pending rows deleted
		var pendingCount int
		err = conn.QueryRow(ctx, `select count(*) from data.pending where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&pendingCount)
		is.NoErr(err)
		is.Equal(pendingCount, 0)

		// verify posted balance updated
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceAfter, balanceBefore+10000)

		// verify balance history created
		var historyCount int
		err = conn.QueryRow(ctx, `select count(*) from data.balances where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&historyCount)
		is.NoErr(err)
		is.Equal(historyCount, 2) // one per account
	})

	t.Run("ReleaseVoidsPending", func(t *testing.T) {
		is := is_.New(t)

		// reserve
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 15000, 300, '2025-03-17', 'To void')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// get balance before
		var balanceBefore int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)

		// release
		_, err = conn.Exec(ctx, `select ledger.release($1)`, txUUID)
		is.NoErr(err)

		// verify status is voided
		var status string
		err = conn.QueryRow(ctx, `select status from data.transactions where uuid = $1`, txUUID).Scan(&status)
		is.NoErr(err)
		is.Equal(status, "voided")

		// verify pending rows deleted
		var pendingCount int
		err = conn.QueryRow(ctx, `select count(*) from data.pending where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&pendingCount)
		is.NoErr(err)
		is.Equal(pendingCount, 0)

		// verify balance unchanged
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceBefore, balanceAfter)
	})

	t.Run("PartialCommit", func(t *testing.T) {
		is := is_.New(t)

		var balanceBefore int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)

		// reserve 20000
		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 20000, 300, '2025-03-18', 'Partial')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// commit only 12000
		_, err = conn.Exec(ctx, `select ledger.commit($1, 12000)`, txUUID)
		is.NoErr(err)

		// verify amount on transaction is 12000 (not 20000)
		var amount int64
		err = conn.QueryRow(ctx, `select amount from data.transactions where uuid = $1`, txUUID).Scan(&amount)
		is.NoErr(err)
		is.Equal(amount, int64(12000))

		// balance changed by 12000 (not 20000)
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceAfter, balanceBefore+12000)
	})

	t.Run("CommitRejectsNonPending", func(t *testing.T) {
		is := is_.New(t)

		// try to commit a posted transaction
		var postedUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-19', 'Posted')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&postedUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, postedUUID)
		is.True(err != nil) // not pending
	})

	t.Run("ReleaseRejectsNonPending", func(t *testing.T) {
		is := is_.New(t)

		var postedUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-19', 'Posted2')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&postedUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.release($1)`, postedUUID)
		is.True(err != nil)
	})

	t.Run("CommitRejectsExcessAmount", func(t *testing.T) {
		is := is_.New(t)

		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 5000, 300, '2025-03-20', 'Excess test')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1, 5001)`, txUUID)
		is.True(err != nil) // exceeds reserved amount
	})

	t.Run("PendingCountsAgainstConstraints", func(t *testing.T) {
		is := is_.New(t)

		// create constrained account with credits_must_not_exceed_debits
		var constrainedUUID, otherUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Constrained 2P', 'asset', null, false, true)
		`, ledgerUUID).Scan(&constrainedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Other 2P', 'equity')
		`, ledgerUUID).Scan(&otherUUID)
		is.NoErr(err)

		// deposit 10000 (debit constrained, credit other)
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-20', 'Deposit')
		`, ledgerUUID, constrainedUUID, otherUUID)
		is.NoErr(err)

		// reserve 8000 (credit constrained = hold against available)
		_, err = conn.Exec(ctx, `
			select ledger.reserve($1, $2, $3, 8000, 300, '2025-03-20', 'Reserve most')
		`, ledgerUUID, otherUUID, constrainedUUID)
		is.NoErr(err)

		// try to reserve 3000 more (8000 pending + 3000 = 11000 > 10000 posted debits)
		_, err = conn.Exec(ctx, `
			select ledger.reserve($1, $2, $3, 3000, 300, '2025-03-20', 'Too much')
		`, ledgerUUID, otherUUID, constrainedUUID)
		is.True(err != nil) // rejected: pending + new > posted
	})

	t.Run("ExpirePending", func(t *testing.T) {
		is := is_.New(t)

		// create a pending with 1-second timeout
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.reserve($1, $2, $3, 1000, 1, '2025-03-21', 'Will expire')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		// wait for expiry
		time.Sleep(2 * time.Second)

		// expire
		var count int
		err = conn.QueryRow(ctx, `select ledger.expire_pending()`).Scan(&count)
		is.NoErr(err)
		is.True(count >= 1)

		// verify status is expired
		var status string
		err = conn.QueryRow(ctx, `select status from data.transactions where uuid = $1`, txUUID).Scan(&status)
		is.NoErr(err)
		is.Equal(status, "expired")

		// verify pending rows cleaned up
		var pendingCount int
		err = conn.QueryRow(ctx, `select count(*) from data.pending where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&pendingCount)
		is.NoErr(err)
		is.Equal(pendingCount, 0)
	})

	t.Run("RegularPostUnaffected", func(t *testing.T) {
		is := is_.New(t)

		// regular post_transaction should still work as before
		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 5000, '2025-03-22', 'Regular')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)

		var status string
		err = conn.QueryRow(ctx, `select status from data.transactions where uuid = $1`, txUUID).Scan(&status)
		is.NoErr(err)
		is.Equal(status, "posted")

		// no pending rows for regular transactions
		var pendingCount int
		err = conn.QueryRow(ctx, `select count(*) from data.pending where transaction_id = (select id from data.transactions where uuid = $1)`, txUUID).Scan(&pendingCount)
		is.NoErr(err)
		is.Equal(pendingCount, 0)
	})
}

func TestIdempotency(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "idempotency_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID, checkingUUID, revenueUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Idempotency Test')`).Scan(&ledgerUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	t.Run("PostWithKey", func(t *testing.T) {
		is := is_.New(t)

		var txUUID string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-01', 'Paycheck', 'key_001')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&txUUID)
		is.NoErr(err)
		is.True(len(txUUID) == 8)
	})

	t.Run("SameKeyReturnsSameUUID", func(t *testing.T) {
		is := is_.New(t)

		// first call
		var uuid1 string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 50000, '2025-03-15', 'Deposit', 'dup_key')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid1)
		is.NoErr(err)

		// second call with same key — should return same uuid, not create duplicate
		var uuid2 string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 50000, '2025-03-15', 'Deposit', 'dup_key')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid2)
		is.NoErr(err)

		is.Equal(uuid1, uuid2) // same transaction returned
	})

	t.Run("SameKeyDifferentDataStillReturnsOriginal", func(t *testing.T) {
		is := is_.New(t)

		// first call
		var uuid1 string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 1000, '2025-03-01', 'Original', 'idempotent_key')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid1)
		is.NoErr(err)

		// second call with same key but different amount/description — still returns original
		var uuid2 string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 9999, '2025-04-01', 'Different', 'idempotent_key')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid2)
		is.NoErr(err)

		is.Equal(uuid1, uuid2) // idempotent, not upsert
	})

	t.Run("NoKeyNoIdempotency", func(t *testing.T) {
		is := is_.New(t)

		// two calls without key — should create two different transactions
		var uuid1, uuid2 string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'No key 1')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid1)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'No key 2')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid2)
		is.NoErr(err)

		is.True(uuid1 != uuid2) // two separate transactions
	})

	t.Run("DifferentKeysDifferentTransactions", func(t *testing.T) {
		is := is_.New(t)

		var uuid1, uuid2 string
		err := conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'A', 'key_a')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid1)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'B', 'key_b')
		`, ledgerUUID, checkingUUID, revenueUUID).Scan(&uuid2)
		is.NoErr(err)

		is.True(uuid1 != uuid2)
	})

	t.Run("BalanceNotDoubled", func(t *testing.T) {
		is := is_.New(t)

		// fresh accounts for clean balance check
		var freshLedger, freshChecking, freshRevenue string
		err := conn.QueryRow(ctx, `select ledger.create_ledger('Balance Dedup Test')`).Scan(&freshLedger)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, freshLedger).Scan(&freshChecking)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, freshLedger).Scan(&freshRevenue)
		is.NoErr(err)

		// post with key
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 25000, '2025-03-01', 'Once', 'once_key')
		`, freshLedger, freshChecking, freshRevenue)
		is.NoErr(err)

		// retry same key
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 25000, '2025-03-01', 'Once', 'once_key')
		`, freshLedger, freshChecking, freshRevenue)
		is.NoErr(err)

		// balance should be 25000, not 50000
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, freshChecking).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(25000)) // not doubled
	})
}

func TestBalanceConstraints(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "constraints_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Constraints Test')`).Scan(&ledgerUUID)
	is.NoErr(err)

	t.Run("AssetNoOverdraft", func(t *testing.T) {
		is := is_.New(t)

		// create asset account with credits_must_not_exceed_debits (can't spend more than you have)
		var checkingUUID, revenueUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'No Overdraft Checking', 'asset',
				null, false, true)
		`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Revenue A', 'equity')
		`, ledgerUUID).Scan(&revenueUUID)
		is.NoErr(err)

		// deposit 10000 (debit checking, credit revenue) — checking debits increase, fine
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-01', 'Deposit')
		`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)

		// spend exactly 10000 (debit revenue, credit checking) — checking credits = debits, fine
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 10000, '2025-03-02', 'Spend all')
		`, ledgerUUID, revenueUUID, checkingUUID)
		is.NoErr(err)

		// try to spend 1 more — should fail (credits would exceed debits)
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 1, '2025-03-03', 'Overdraft')
		`, ledgerUUID, revenueUUID, checkingUUID)
		is.True(err != nil) // rejected: would exceed debit balance
	})

	t.Run("EquityNoOverspend", func(t *testing.T) {
		is := is_.New(t)

		// create equity account with debits_must_not_exceed_credits (can't withdraw more than funded)
		var categoryUUID, fundingUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Capped Category', 'equity',
				null, true, false)
		`, ledgerUUID).Scan(&categoryUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Funding Source', 'equity')
		`, ledgerUUID).Scan(&fundingUUID)
		is.NoErr(err)

		// fund category: 5000 (debit funding, credit category) — category credits increase
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 5000, '2025-03-01', 'Fund')
		`, ledgerUUID, fundingUUID, categoryUUID)
		is.NoErr(err)

		// withdraw exactly 5000 (debit category, credit funding) — category debits = credits
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 5000, '2025-03-02', 'Withdraw all')
		`, ledgerUUID, categoryUUID, fundingUUID)
		is.NoErr(err)

		// try to withdraw 1 more — should fail
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 1, '2025-03-03', 'Overspend')
		`, ledgerUUID, categoryUUID, fundingUUID)
		is.True(err != nil) // rejected: would exceed credit balance
	})

	t.Run("DefaultNoConstraints", func(t *testing.T) {
		is := is_.New(t)

		// default account: no constraints, negative balance allowed
		var acctUUID, otherUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Unconstrained', 'asset')
		`, ledgerUUID).Scan(&acctUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Other', 'equity')
		`, ledgerUUID).Scan(&otherUUID)
		is.NoErr(err)

		// credit without any prior debit — negative balance, but allowed
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 99999, '2025-03-01', 'Go negative')
		`, ledgerUUID, otherUUID, acctUUID)
		is.NoErr(err)

		// balance is -99999 for asset (debits 0 - credits 99999)
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, acctUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(-99999))
	})

	t.Run("ConstraintOnlyAffectsConstrainedAccount", func(t *testing.T) {
		is := is_.New(t)

		// constrained account paired with unconstrained account
		// the unconstrained side should not be affected
		var constrainedUUID, freeUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Constrained Acct', 'equity', null, true, false)
		`, ledgerUUID).Scan(&constrainedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Free Acct', 'equity')
		`, ledgerUUID).Scan(&freeUUID)
		is.NoErr(err)

		// try to debit constrained account without any credits — should fail
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'Should fail')
		`, ledgerUUID, constrainedUUID, freeUUID)
		is.True(err != nil) // constrained: debits would exceed credits (0)

		// reverse direction: credit constrained, debit free — should work
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 100, '2025-03-01', 'Should work')
		`, ledgerUUID, freeUUID, constrainedUUID)
		is.NoErr(err)
	})

	t.Run("FastPathStillWorks", func(t *testing.T) {
		is := is_.New(t)

		// two unconstrained accounts — should use fast path
		var aUUID, bUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Fast A', 'asset')`, ledgerUUID).Scan(&aUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Fast B', 'equity')`, ledgerUUID).Scan(&bUUID)
		is.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 50000, '2025-03-01', 'Fast path')
		`, ledgerUUID, aUUID, bUUID).Scan(&txUUID)
		is.NoErr(err)
		is.True(len(txUUID) == 8)

		// verify counters and balance history still work
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, aUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(50000))
	})

	t.Run("BatchRespectsConstraints", func(t *testing.T) {
		is := is_.New(t)

		var cappedUUID, sourceUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Batch Capped', 'equity', null, true, false)
		`, ledgerUUID).Scan(&cappedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Batch Source', 'equity')
		`, ledgerUUID).Scan(&sourceUUID)
		is.NoErr(err)

		// fund 1000
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 1000, '2025-03-01', 'Fund')
		`, ledgerUUID, sourceUUID, cappedUUID)
		is.NoErr(err)

		// batch: first withdraws 500 (ok), second withdraws 600 (would exceed) — whole batch fails
		_, err = conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 500, "description": "OK"},
			{"debit": "%s", "credit": "%s", "amount": 600, "description": "Too much"}
		]`, cappedUUID, sourceUUID, cappedUUID, sourceUUID))
		is.True(err != nil) // whole batch rejected

		// balance unchanged — atomic rollback
		var balance int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, cappedUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(1000)) // unchanged
	})
}

func TestPostTransactions(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	testUserID := "batch_test_user"
	err = setTestUserContext(ctx, conn, testUserID)
	is.NoErr(err)

	var ledgerUUID, checkingUUID, savingsUUID, revenueUUID string

	err = conn.QueryRow(ctx, `select ledger.create_ledger('Batch Test')`).Scan(&ledgerUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking', 'asset')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings', 'asset')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue', 'equity')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	t.Run("BatchOfThree", func(t *testing.T) {
		is := is_.New(t)

		var uuids []string
		err := conn.QueryRow(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 100000, "date": "2025-03-01", "description": "Paycheck"},
			{"debit": "%s", "credit": "%s", "amount": 30000, "date": "2025-03-05", "description": "To savings"},
			{"debit": "%s", "credit": "%s", "amount": 50000, "date": "2025-03-15", "description": "Freelance"}
		]`, checkingUUID, revenueUUID, savingsUUID, checkingUUID, checkingUUID, revenueUUID)).Scan(&uuids)
		is.NoErr(err)
		is.Equal(len(uuids), 3)
		is.True(len(uuids[0]) == 8)
		is.True(len(uuids[1]) == 8)
		is.True(len(uuids[2]) == 8)
	})

	t.Run("BalancesCorrectAfterBatch", func(t *testing.T) {
		is := is_.New(t)

		// checking: debited 100000 + 50000, credited 30000 → 120000
		var balance int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(120000))

		// savings: debited 30000 → 30000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, savingsUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(30000))

		// revenue: credited 150000 → 150000
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, revenueUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(150000))
	})

	t.Run("BalanceHistoryIsSequential", func(t *testing.T) {
		is := is_.New(t)

		// checking has 3 transactions — running balances should be sequential, not all the same
		type historyRow struct {
			Amount         int64
			RunningBalance int64
		}

		rows, err := conn.Query(ctx, `
			select amount, running_balance from ledger.get_history($1)
		`, checkingUUID)
		is.NoErr(err)
		defer rows.Close()

		var history []historyRow
		for rows.Next() {
			var h historyRow
			err := rows.Scan(&h.Amount, &h.RunningBalance)
			is.NoErr(err)
			history = append(history, h)
		}
		is.NoErr(rows.Err())

		is.Equal(len(history), 3)
		// newest first
		is.Equal(history[0].RunningBalance, int64(120000)) // after freelance
		is.Equal(history[1].RunningBalance, int64(70000))  // after savings transfer
		is.Equal(history[2].RunningBalance, int64(100000)) // after paycheck
	})

	t.Run("EmptyArray", func(t *testing.T) {
		is := is_.New(t)

		var uuids []string
		err := conn.QueryRow(ctx, `select ledger.post_transactions($1, '[]'::jsonb)`, ledgerUUID).Scan(&uuids)
		is.NoErr(err)
		is.Equal(len(uuids), 0)
	})

	t.Run("RejectsInvalidAccount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 1000, "description": "Good"},
			{"debit": "nonexistent", "credit": "%s", "amount": 1000, "description": "Bad"}
		]`, checkingUUID, revenueUUID, revenueUUID))
		is.True(err != nil)
	})

	t.Run("RejectsZeroAmount", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 0, "description": "Zero"}
		]`, checkingUUID, revenueUUID))
		is.True(err != nil)
	})

	t.Run("AtomicRollback", func(t *testing.T) {
		is := is_.New(t)

		// get balance before
		var balanceBefore int64
		err := conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)

		// batch with one good + one bad — should all roll back
		_, err = conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[
			{"debit": "%s", "credit": "%s", "amount": 99999, "description": "Good one"},
			{"debit": "%s", "credit": "%s", "amount": -1, "description": "Bad one"}
		]`, checkingUUID, revenueUUID, checkingUUID, revenueUUID))
		is.True(err != nil) // should fail

		// balance should be unchanged
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceBefore, balanceAfter) // no change — batch rolled back
	})

	t.Run("RejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transactions('nonexistent', $1::jsonb)
		`, fmt.Sprintf(`[{"debit": "%s", "credit": "%s", "amount": 1000}]`, checkingUUID, revenueUUID))
		is.True(err != nil)
	})

	t.Run("RejectsNonArray", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `
			select ledger.post_transactions($1, '{"not": "array"}'::jsonb)
		`, ledgerUUID)
		is.True(err != nil)
	})

	t.Run("RejectsMissingFields", func(t *testing.T) {
		is := is_.New(t)

		// missing amount
		_, err := conn.Exec(ctx, `
			select ledger.post_transactions($1, $2::jsonb)
		`, ledgerUUID, fmt.Sprintf(`[{"debit": "%s", "credit": "%s"}]`, checkingUUID, revenueUUID))
		is.True(err != nil)
	})
}

func TestBalancesTable(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	t.Run("TableExists", func(t *testing.T) {
		is := is_.New(t)

		var exists bool
		err := conn.QueryRow(ctx, `
			select exists (
				select 1 from information_schema.tables
				where table_schema = 'data' and table_name = 'balances'
			)
		`).Scan(&exists)
		is.NoErr(err)
		is.True(exists)
	})

	t.Run("RLSEnabled", func(t *testing.T) {
		is := is_.New(t)

		var rlsEnabled bool
		err := conn.QueryRow(ctx, `
			select relrowsecurity from pg_class
			where oid = 'data.balances'::regclass
		`).Scan(&rlsEnabled)
		is.NoErr(err)
		is.True(rlsEnabled)
	})
}
