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


// getBalance fetches raw counters from ledger.get_balance
func getBalance(ctx context.Context, conn *pgx.Conn, accountUUID string) (int64, int64, error) {
	var debits, credits int64
	err := conn.QueryRow(ctx,
		`select debits_total, credits_total from ledger.get_balance($1)`,
		accountUUID,
	).Scan(&debits, &credits)
	return debits, credits, err
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

		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		is.True(len(checkingUUID) == 8)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings')`, ledgerUUID).Scan(&savingsUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Visa')`, ledgerUUID).Scan(&visaUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&incomeUUID)
		is.NoErr(err)
	})

	t.Run("CreateAccountRejectsEmptyName", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_account($1, '')`, ledgerUUID)
		is.True(err != nil)
	})

	t.Run("CreateAccountRejectsInvalidLedger", func(t *testing.T) {
		is := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.create_account('nonexistent', 'Checking')`)
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

		var debits, credits int64

		// checking: debits=100000 credits=25000
		debits, credits, err := getBalance(ctx, conn, checkingUUID)
		is.NoErr(err)
		is.Equal(debits, int64(100000))
		is.Equal(credits, int64(25000))

		// income: debits=0 credits=100000
		debits, credits, err = getBalance(ctx, conn, incomeUUID)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(100000))

		// visa: debits=25000 credits=0
		debits, credits, err = getBalance(ctx, conn, visaUUID)
		is.NoErr(err)
		is.Equal(debits, int64(25000))
		is.Equal(credits, int64(0))
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

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, voidLedgerUUID).Scan(&voidCheckingUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, voidLedgerUUID).Scan(&voidIncomeUUID)
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

		// verify counters before void
		debits, credits, err := getBalance(ctx, conn, voidCheckingUUID)
		is.NoErr(err)
		is.Equal(debits, int64(50000))
		is.Equal(credits, int64(0))

		// void it
		var reversalUUID string
		err = conn.QueryRow(ctx, `select ledger.void($1, 'Wrong amount')`, txUUID).Scan(&reversalUUID)
		is.NoErr(err)
		is.True(len(reversalUUID) == 8)

		// after void: reversal credits the same amount back, net zero
		debits, credits, err = getBalance(ctx, conn, voidCheckingUUID)
		is.NoErr(err)
		is.Equal(debits, int64(50000))
		is.Equal(credits, int64(50000))
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
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, freshLedger).Scan(&freshChecking)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, freshLedger).Scan(&freshIncome)
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

		// checking: original 10000 debit + reversal 10000 credit + new 15000 debit
		debits, credits, err := getBalance(ctx, conn, freshChecking)
		is.NoErr(err)
		is.Equal(debits, int64(25000))  // 10000 + 15000
		is.Equal(credits, int64(10000)) // reversal
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
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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

		// checking: debits=150000, credits=30000
		debits, credits, err := getBalance(ctx, conn, checkingUUID)
		is.NoErr(err)
		is.Equal(debits, int64(150000))
		is.Equal(credits, int64(30000))

		// savings: debits=30000, credits=0
		debits, credits, err = getBalance(ctx, conn, savingsUUID)
		is.NoErr(err)
		is.Equal(debits, int64(30000))
		is.Equal(credits, int64(0))

		// revenue: debits=0, credits=150000
		debits, credits, err = getBalance(ctx, conn, revenueUUID)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(150000))
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
			Debits  int64
			Credits int64
		}

		rows, err := conn.Query(ctx, `select * from ledger.get_balances($1)`, ledgerUUID)
		is.NoErr(err)
		defer rows.Close()

		var balances []accountBalance
		for rows.Next() {
			var ab accountBalance
			err := rows.Scan(&ab.UUID, &ab.Name, &ab.Debits, &ab.Credits)
			is.NoErr(err)
			balances = append(balances, ab)
		}
		is.NoErr(rows.Err())

		// should have at least our 3 accounts
		is.True(len(balances) >= 3)

		// find our accounts and verify counters
		var foundChecking, foundSavings, foundRevenue bool
		for _, ab := range balances {
			switch ab.UUID {
			case checkingUUID:
				is.Equal(ab.Debits, int64(150000))
				is.Equal(ab.Credits, int64(30000))
				foundChecking = true
			case savingsUUID:
				is.Equal(ab.Debits, int64(30000))
				is.Equal(ab.Credits, int64(0))
				foundSavings = true
			case revenueUUID:
				is.Equal(ab.Debits, int64(0))
				is.Equal(ab.Credits, int64(150000))
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
			TxUUID       string
			Date         time.Time
			Description  string
			Counterparty string
			Amount       int64
			Direction    string
			DebitsTotal  int64
			CreditsTotal int64
		}

		rows, err := conn.Query(ctx, `select * from ledger.get_history($1)`, checkingUUID)
		is.NoErr(err)
		defer rows.Close()

		var history []historyRow
		for rows.Next() {
			var h historyRow
			err := rows.Scan(&h.TxUUID, &h.Date, &h.Description, &h.Counterparty, &h.Amount, &h.Direction, &h.DebitsTotal, &h.CreditsTotal)
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
		is.Equal(history[0].DebitsTotal, int64(150000))
		is.Equal(history[0].CreditsTotal, int64(30000))

		// middle: To savings (credit checking 30000)
		is.Equal(history[1].Description, "To savings")
		is.Equal(history[1].Amount, int64(30000))
		is.Equal(history[1].Direction, "credit")
		is.Equal(history[1].DebitsTotal, int64(100000))
		is.Equal(history[1].CreditsTotal, int64(30000))

		// oldest: Paycheck (debit checking 100000)
		is.Equal(history[2].Description, "Paycheck")
		is.Equal(history[2].Amount, int64(100000))
		is.Equal(history[2].Direction, "debit")
		is.Equal(history[2].DebitsTotal, int64(100000))
		is.Equal(history[2].CreditsTotal, int64(0))
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

	// manually create the clearing account (internal, for linked transfers)
	var clearingUUID string
	err = conn.QueryRow(ctx, `
		insert into data.accounts (name, ledger_id, user_data, visibility)
		values ('clearing', (select id from data.ledgers where uuid = $1), $2, 'internal')
		returning uuid
	`, ledgerUUID, testUserID).Scan(&clearingUUID)
	is.NoErr(err)

	// create user accounts
	var checkingUUID, visaUUID, revenueUUID string
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Visa')`, ledgerUUID).Scan(&visaUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
	is.NoErr(err)

	// seed checking with balance
	_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 500000, '2025-03-01', 'Seed')`, ledgerUUID, checkingUUID, revenueUUID)
	is.NoErr(err)

	t.Run("ClearingAccountVisibility", func(t *testing.T) {
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

		debits, credits, err := getBalance(ctx, conn, clearingUUID)
		is.NoErr(err)
		is.Equal(debits, credits) // clearing always nets to zero
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

		// clearing still nets to zero
		debits, credits, err := getBalance(ctx, conn, clearingUUID)
		is.NoErr(err)
		is.Equal(debits, credits)
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
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Open Acct')`, ledgerUUID).Scan(&openAcctUUID)
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
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Visa')`, ledgerUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID)
		is.NoErr(err)

		type account struct {
			UUID        string
			Name        string
			Description *string
		}

		rows, err := conn.Query(ctx, `select account_uuid, account_name, description from ledger.get_accounts($1)`, ledgerUUID)
		is.NoErr(err)
		defer rows.Close()

		var accounts []account
		for rows.Next() {
			var a account
			err := rows.Scan(&a.UUID, &a.Name, &a.Description)
			is.NoErr(err)
			accounts = append(accounts, a)
		}
		is.NoErr(rows.Err())

		// should have our 3 accounts
		is.True(len(accounts) >= 3)

		// verify our accounts are present
		names := make(map[string]bool)
		for _, a := range accounts {
			names[a.Name] = true
		}
		is.True(names["Checking"])
		is.True(names["Visa"])
		is.True(names["Revenue"])
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

		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
		is.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 50000, '2025-03-01', 'First')`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 30000, '2025-03-15', 'Second')`, ledgerUUID, checkingUUID, revenueUUID)
		is.NoErr(err)

		// verify correct balance before rebuild
		var balanceBefore int64
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
		is.NoErr(err)
		is.Equal(balanceBefore, int64(80000))

		// manually corrupt the counters
		_, err = conn.Exec(ctx, `update data.accounts set debits_total = 0, credits_total = 0 where uuid = $1`, checkingUUID)
		is.NoErr(err)

		// verify balance is now wrong
		var corruptedBalance int64
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&corruptedBalance)
		is.NoErr(err)
		is.Equal(corruptedBalance, int64(0)) // corrupted

		// rebuild
		_, err = conn.Exec(ctx, `select ledger.rebuild_balances($1)`, ledgerUUID)
		is.NoErr(err)

		// verify balance is restored
		var balanceAfter int64
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
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
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balance)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
		is.NoErr(err)
		is.Equal(balanceBefore, balanceAfter)
	})

	t.Run("PartialCommit", func(t *testing.T) {
		is := is_.New(t)

		var balanceBefore int64
		err := conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
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
			select ledger.create_account($1, 'Constrained 2P', null, false, true)
		`, ledgerUUID).Scan(&constrainedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Other 2P')
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
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, freshLedger).Scan(&freshChecking)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, freshLedger).Scan(&freshRevenue)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, freshChecking).Scan(&balance)
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
			select ledger.create_account($1, 'No Overdraft Checking',
				null, false, true)
		`, ledgerUUID).Scan(&checkingUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Revenue A')
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
			select ledger.create_account($1, 'Capped Category',
				null, true, false)
		`, ledgerUUID).Scan(&categoryUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Funding Source')
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
			select ledger.create_account($1, 'Unconstrained')
		`, ledgerUUID).Scan(&acctUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Other')
		`, ledgerUUID).Scan(&otherUUID)
		is.NoErr(err)

		// credit without any prior debit — negative balance, but allowed
		_, err = conn.Exec(ctx, `
			select ledger.post_transaction($1, $2, $3, 99999, '2025-03-01', 'Go negative')
		`, ledgerUUID, otherUUID, acctUUID)
		is.NoErr(err)

		// raw counters: debits=0 credits=99999
		debits, credits, err := getBalance(ctx, conn, acctUUID)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(99999))
	})

	t.Run("ConstraintOnlyAffectsConstrainedAccount", func(t *testing.T) {
		is := is_.New(t)

		// constrained account paired with unconstrained account
		// the unconstrained side should not be affected
		var constrainedUUID, freeUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Constrained Acct', null, true, false)
		`, ledgerUUID).Scan(&constrainedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Free Acct')
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
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Fast A')`, ledgerUUID).Scan(&aUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Fast B')`, ledgerUUID).Scan(&bUUID)
		is.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 50000, '2025-03-01', 'Fast path')
		`, ledgerUUID, aUUID, bUUID).Scan(&txUUID)
		is.NoErr(err)
		is.True(len(txUUID) == 8)

		// verify counters and balance history still work
		var balance int64
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, aUUID).Scan(&balance)
		is.NoErr(err)
		is.Equal(balance, int64(50000))
	})

	t.Run("BatchRespectsConstraints", func(t *testing.T) {
		is := is_.New(t)

		var cappedUUID, sourceUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Batch Capped', null, true, false)
		`, ledgerUUID).Scan(&cappedUUID)
		is.NoErr(err)

		err = conn.QueryRow(ctx, `
			select ledger.create_account($1, 'Batch Source')
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

		// credits unchanged — atomic rollback
		debits, credits, err := getBalance(ctx, conn, cappedUUID)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(1000)) // unchanged
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
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerUUID).Scan(&checkingUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Savings')`, ledgerUUID).Scan(&savingsUUID)
	is.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Revenue')`, ledgerUUID).Scan(&revenueUUID)
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

		// checking: debited 100000+50000=150000, credited 30000
		debits, credits, err := getBalance(ctx, conn, checkingUUID)
		is.NoErr(err)
		is.Equal(debits, int64(150000))
		is.Equal(credits, int64(30000))

		// savings: debited 30000
		debits, credits, err = getBalance(ctx, conn, savingsUUID)
		is.NoErr(err)
		is.Equal(debits, int64(30000))
		is.Equal(credits, int64(0))

		// revenue: credited 150000
		debits, credits, err = getBalance(ctx, conn, revenueUUID)
		is.NoErr(err)
		is.Equal(debits, int64(0))
		is.Equal(credits, int64(150000))
	})

	t.Run("BalanceHistoryIsSequential", func(t *testing.T) {
		is := is_.New(t)

		// checking has 3 transactions — counters should be sequential
		type historyRow struct {
			Amount       int64
			DebitsTotal  int64
			CreditsTotal int64
		}

		rows, err := conn.Query(ctx, `
			select amount, debits_total, credits_total from ledger.get_history($1)
		`, checkingUUID)
		is.NoErr(err)
		defer rows.Close()

		var history []historyRow
		for rows.Next() {
			var h historyRow
			err := rows.Scan(&h.Amount, &h.DebitsTotal, &h.CreditsTotal)
			is.NoErr(err)
			history = append(history, h)
		}
		is.NoErr(rows.Err())

		is.Equal(len(history), 3)
		// newest first — raw counters
		is.Equal(history[0].DebitsTotal, int64(150000)) // after freelance
		is.Equal(history[1].DebitsTotal, int64(100000)) // after savings transfer (credit, debits unchanged)
		is.Equal(history[2].DebitsTotal, int64(100000)) // after paycheck
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
		err := conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceBefore)
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
		err = conn.QueryRow(ctx, `select debits_total from ledger.get_balance($1)`, checkingUUID).Scan(&balanceAfter)
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

// --- Helper types and functions for engine guarantee tests ---

type Transaction struct {
	UUID             string
	Amount           int64
	Description      *string
	Status           string
	DebitAccountID   int64
	CreditAccountID  int64
	CreatedAt        time.Time
}

type BalanceRow struct {
	AccountID     int64
	TransactionID int64
	DebitsTotal   int64
	CreditsTotal  int64
}

func countTransactions(ctx context.Context, conn *pgx.Conn) (int, error) {
	var count int
	err := conn.QueryRow(ctx, `select count(*) from data.transactions`).Scan(&count)
	return count, err
}

func countBalances(ctx context.Context, conn *pgx.Conn) (int, error) {
	var count int
	err := conn.QueryRow(ctx, `select count(*) from data.balances`).Scan(&count)
	return count, err
}

func countPending(ctx context.Context, conn *pgx.Conn) (int, error) {
	var count int
	err := conn.QueryRow(ctx, `select count(*) from data.pending`).Scan(&count)
	return count, err
}

func getTransactionByUUID(ctx context.Context, conn *pgx.Conn, uuid string) (Transaction, error) {
	var t Transaction
	err := conn.QueryRow(ctx, `
		select uuid, amount, description, status, debit_account_id, credit_account_id, created_at
		from data.transactions where uuid = $1
	`, uuid).Scan(&t.UUID, &t.Amount, &t.Description, &t.Status, &t.DebitAccountID, &t.CreditAccountID, &t.CreatedAt)
	return t, err
}

func getBalanceHistory(ctx context.Context, conn *pgx.Conn, accountUUID string) ([]BalanceRow, error) {
	rows, err := conn.Query(ctx, `
		select b.account_id, b.transaction_id, b.debits_total, b.credits_total
		from data.balances b
		join data.accounts a on a.id = b.account_id
		where a.uuid = $1
		order by b.transaction_id asc
	`, accountUUID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []BalanceRow
	for rows.Next() {
		var r BalanceRow
		if err := rows.Scan(&r.AccountID, &r.TransactionID, &r.DebitsTotal, &r.CreditsTotal); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, rows.Err()
}

// --- Engine guarantee tests ---

func TestAppendOnlyImmutability(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "immutability_test_user")
	assert.NoErr(err)

	// setup: ledger + two accounts
	var ledgerUUID, acctA, acctB string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Immutability Test')`).Scan(&ledgerUUID)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Account A')`, ledgerUUID).Scan(&acctA)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Account B')`, ledgerUUID).Scan(&acctB)
	assert.NoErr(err)

	t.Run("RowCountIncreasesAfterPost", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 1000)`, ledgerUUID, acctA, acctB)
		assert.NoErr(err)

		after, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 1) // exactly one new row
	})

	// post a transaction we'll void and correct later
	var txUUID string
	err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 5000, current_date, 'Original')`,
		ledgerUUID, acctA, acctB).Scan(&txUUID)
	assert.NoErr(err)

	// snapshot the original transaction
	origTx, err := getTransactionByUUID(ctx, conn, txUUID)
	assert.NoErr(err)

	t.Run("RowCountIncreasesAfterVoid", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.void($1)`, txUUID)
		assert.NoErr(err)

		after, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 1) // reversal is a new row
	})

	t.Run("OriginalTransactionUntouchedAfterVoid", func(t *testing.T) {
		assert := is_.New(t)

		current, err := getTransactionByUUID(ctx, conn, txUUID)
		assert.NoErr(err)
		assert.Equal(current.Amount, origTx.Amount)
		assert.Equal(current.DebitAccountID, origTx.DebitAccountID)
		assert.Equal(current.CreditAccountID, origTx.CreditAccountID)
		assert.Equal(current.CreatedAt, origTx.CreatedAt)
	})

	t.Run("VoidReversalHasSwappedAccounts", func(t *testing.T) {
		assert := is_.New(t)

		// the reversal is the most recent transaction
		var reversalDebit, reversalCredit int64
		err := conn.QueryRow(ctx, `
			select debit_account_id, credit_account_id
			from data.transactions
			where description like 'VOIDED:%' and amount = $1
			order by created_at desc limit 1
		`, origTx.Amount).Scan(&reversalDebit, &reversalCredit)
		assert.NoErr(err)
		assert.Equal(reversalDebit, origTx.CreditAccountID)  // swapped
		assert.Equal(reversalCredit, origTx.DebitAccountID)   // swapped
	})

	// post another transaction to test correct
	var tx2UUID string
	err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 8000, current_date, 'To correct')`,
		ledgerUUID, acctA, acctB).Scan(&tx2UUID)
	assert.NoErr(err)
	origTx2, err := getTransactionByUUID(ctx, conn, tx2UUID)
	assert.NoErr(err)

	t.Run("RowCountIncreasesAfterCorrect", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.correct($1, null, null, 12000)`, tx2UUID)
		assert.NoErr(err)

		after, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 2) // reversal + correction
	})

	t.Run("OriginalTransactionUntouchedAfterCorrect", func(t *testing.T) {
		assert := is_.New(t)

		current, err := getTransactionByUUID(ctx, conn, tx2UUID)
		assert.NoErr(err)
		assert.Equal(current.Amount, origTx2.Amount)             // still 8000
		assert.Equal(current.DebitAccountID, origTx2.DebitAccountID)
		assert.Equal(current.CreditAccountID, origTx2.CreditAccountID)
	})

	t.Run("BalanceHistoryOnlyGrows", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 2000)`, ledgerUUID, acctA, acctB)
		assert.NoErr(err)

		after, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 2) // one row per account
	})

	t.Run("BalanceHistoryGrowsOnVoid", func(t *testing.T) {
		assert := is_.New(t)

		var voidTarget string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 3000)`,
			ledgerUUID, acctA, acctB).Scan(&voidTarget)
		assert.NoErr(err)

		before, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.void($1)`, voidTarget)
		assert.NoErr(err)

		after, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 2) // reversal adds 2 balance rows
	})

	t.Run("BalanceHistoryGrowsOnCorrect", func(t *testing.T) {
		assert := is_.New(t)

		var correctTarget string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 4000)`,
			ledgerUUID, acctA, acctB).Scan(&correctTarget)
		assert.NoErr(err)

		before, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.correct($1, null, null, 6000)`, correctTarget)
		assert.NoErr(err)

		after, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after-before, 4) // reversal (2) + correction (2)
	})

	t.Run("TransactionLogIsAppendOnly", func(t *testing.T) {
		assert := is_.New(t)

		var logTarget string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 1500)`,
			ledgerUUID, acctA, acctB).Scan(&logTarget)
		assert.NoErr(err)

		var logBefore int
		err = conn.QueryRow(ctx, `select count(*) from data.transaction_log`).Scan(&logBefore)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.void($1)`, logTarget)
		assert.NoErr(err)

		var logAfter int
		err = conn.QueryRow(ctx, `select count(*) from data.transaction_log`).Scan(&logAfter)
		assert.NoErr(err)
		assert.True(logAfter > logBefore) // at least one new log entry
	})

	t.Run("CorrectReversalMatchesOriginal", func(t *testing.T) {
		assert := is_.New(t)

		var target string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 7777, current_date, 'Seven')`,
			ledgerUUID, acctA, acctB).Scan(&target)
		assert.NoErr(err)

		orig, err := getTransactionByUUID(ctx, conn, target)
		assert.NoErr(err)

		beforeCount, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.correct($1, null, null, 9999)`, target)
		assert.NoErr(err)

		// correct creates 2 new rows: reversal + correction
		// the reversal is the first of the two new rows (lower id)
		var revAmount int64
		var revDebit, revCredit int64
		err = conn.QueryRow(ctx, `
			select amount, debit_account_id, credit_account_id
			from data.transactions
			where amount = $1
			  and debit_account_id = $2
			  and credit_account_id = $3
			order by id desc limit 1
		`, orig.Amount, orig.CreditAccountID, orig.DebitAccountID).Scan(&revAmount, &revDebit, &revCredit)
		assert.NoErr(err)
		assert.Equal(revAmount, orig.Amount)
		assert.Equal(revDebit, orig.CreditAccountID)  // swapped
		assert.Equal(revCredit, orig.DebitAccountID)   // swapped

		afterCount, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(afterCount-beforeCount, 2) // reversal + correction
	})
}

func TestBalanceCorrectnessInvariants(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "balance_correctness_user")
	assert.NoErr(err)

	var ledgerUUID, acctA, acctB string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Balance Correctness')`).Scan(&ledgerUUID)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Acct A')`, ledgerUUID).Scan(&acctA)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Acct B')`, ledgerUUID).Scan(&acctB)
	assert.NoErr(err)

	t.Run("SinglePostBothAccountsCorrect", func(t *testing.T) {
		assert := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 50000)`, ledgerUUID, acctA, acctB)
		assert.NoErr(err)

		dA, cA, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)
		assert.Equal(dA, int64(50000)) // A was debited
		assert.Equal(cA, int64(0))

		dB, cB, err := getBalance(ctx, conn, acctB)
		assert.NoErr(err)
		assert.Equal(dB, int64(0))
		assert.Equal(cB, int64(50000)) // B was credited
	})

	t.Run("MultiplePostsAccumulate", func(t *testing.T) {
		assert := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 20000)`, ledgerUUID, acctA, acctB)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 30000)`, ledgerUUID, acctA, acctB)
		assert.NoErr(err)

		dA, cA, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)
		assert.Equal(dA, int64(100000)) // 50000 + 20000 + 30000
		assert.Equal(cA, int64(0))

		dB, cB, err := getBalance(ctx, conn, acctB)
		assert.NoErr(err)
		assert.Equal(dB, int64(0))
		assert.Equal(cB, int64(100000))
	})

	t.Run("VoidResetsNetToZero", func(t *testing.T) {
		assert := is_.New(t)

		// use fresh accounts so counters are clean
		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Void A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Void B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, a1, a2).Scan(&txUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.void($1)`, txUUID)
		assert.NoErr(err)

		d1, c1, err := getBalance(ctx, conn, a1)
		assert.NoErr(err)
		assert.Equal(d1, c1) // net zero

		d2, c2, err := getBalance(ctx, conn, a2)
		assert.NoErr(err)
		assert.Equal(d2, c2) // net zero
	})

	t.Run("CorrectNetIsNewAmount", func(t *testing.T) {
		assert := is_.New(t)

		var c1, c2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Correct A')`, ledgerUUID).Scan(&c1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Correct B')`, ledgerUUID).Scan(&c2)
		assert.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, c1, c2).Scan(&txUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.correct($1, null, null, 15000)`, txUUID)
		assert.NoErr(err)

		// c1: debited 10000 (orig) + credited 10000 (reversal) + debited 15000 (correction)
		d1, cr1, err := getBalance(ctx, conn, c1)
		assert.NoErr(err)
		assert.Equal(d1, int64(25000))  // 10000 + 15000
		assert.Equal(cr1, int64(10000)) // reversal
		// net = 25000 - 10000 = 15000 (the corrected amount)
	})

	t.Run("BalanceHistorySnapshotAfterEachPost", func(t *testing.T) {
		assert := is_.New(t)

		var h1, h2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Hist A')`, ledgerUUID).Scan(&h1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Hist B')`, ledgerUUID).Scan(&h2)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 1000)`, ledgerUUID, h1, h2)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 2000)`, ledgerUUID, h1, h2)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 3000)`, ledgerUUID, h1, h2)
		assert.NoErr(err)

		history, err := getBalanceHistory(ctx, conn, h1)
		assert.NoErr(err)
		assert.Equal(len(history), 3)
		assert.Equal(history[0].DebitsTotal, int64(1000))  // after 1st
		assert.Equal(history[1].DebitsTotal, int64(3000))  // after 2nd (1000+2000)
		assert.Equal(history[2].DebitsTotal, int64(6000))  // after 3rd (1000+2000+3000)
	})

	t.Run("ReserveDoesNotAffectPostedCounters", func(t *testing.T) {
		assert := is_.New(t)

		var r1, r2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Reserve A')`, ledgerUUID).Scan(&r1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Reserve B')`, ledgerUUID).Scan(&r2)
		assert.NoErr(err)

		d1Before, c1Before, err := getBalance(ctx, conn, r1)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 5000)`, ledgerUUID, r1, r2)
		assert.NoErr(err)

		d1After, c1After, err := getBalance(ctx, conn, r1)
		assert.NoErr(err)
		assert.Equal(d1Before, d1After)   // unchanged
		assert.Equal(c1Before, c1After)   // unchanged
	})

	t.Run("CommitCreatesBalanceHistory", func(t *testing.T) {
		assert := is_.New(t)

		var cm1, cm2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Commit A')`, ledgerUUID).Scan(&cm1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Commit B')`, ledgerUUID).Scan(&cm2)
		assert.NoErr(err)

		var pendingUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 7000)`,
			ledgerUUID, cm1, cm2).Scan(&pendingUUID)
		assert.NoErr(err)

		balBefore, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, pendingUUID)
		assert.NoErr(err)

		balAfter, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(balAfter-balBefore, 2) // one per account
	})

	t.Run("ReleaseDoesNotCreateBalanceHistory", func(t *testing.T) {
		assert := is_.New(t)

		var rl1, rl2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Release A')`, ledgerUUID).Scan(&rl1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Release B')`, ledgerUUID).Scan(&rl2)
		assert.NoErr(err)

		var pendingUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 3000)`,
			ledgerUUID, rl1, rl2).Scan(&pendingUUID)
		assert.NoErr(err)

		balBefore, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.release($1)`, pendingUUID)
		assert.NoErr(err)

		balAfter, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(balAfter, balBefore) // no change
	})

	t.Run("PartialCommitCountersMatchCommitAmount", func(t *testing.T) {
		assert := is_.New(t)

		var p1, p2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Partial A')`, ledgerUUID).Scan(&p1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Partial B')`, ledgerUUID).Scan(&p2)
		assert.NoErr(err)

		var pendingUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 20000)`,
			ledgerUUID, p1, p2).Scan(&pendingUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1, 8000)`, pendingUUID)
		assert.NoErr(err)

		d1, c1, err := getBalance(ctx, conn, p1)
		assert.NoErr(err)
		assert.Equal(d1, int64(8000)) // commit amount, not reserved
		assert.Equal(c1, int64(0))
	})

	t.Run("FullCommitCountersMatchReservedAmount", func(t *testing.T) {
		assert := is_.New(t)

		var f1, f2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Full A')`, ledgerUUID).Scan(&f1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Full B')`, ledgerUUID).Scan(&f2)
		assert.NoErr(err)

		var pendingUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 15000)`,
			ledgerUUID, f1, f2).Scan(&pendingUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, pendingUUID)
		assert.NoErr(err)

		d1, _, err := getBalance(ctx, conn, f1)
		assert.NoErr(err)
		assert.Equal(d1, int64(15000))
	})

	t.Run("RebuildBalancesProducesSameResult", func(t *testing.T) {
		assert := is_.New(t)

		var rb1, rb2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Rebuild A')`, ledgerUUID).Scan(&rb1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Rebuild B')`, ledgerUUID).Scan(&rb2)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 1000)`, ledgerUUID, rb1, rb2)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 2000)`, ledgerUUID, rb1, rb2)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 3000)`, ledgerUUID, rb2, rb1)
		assert.NoErr(err)

		d1Before, c1Before, err := getBalance(ctx, conn, rb1)
		assert.NoErr(err)
		d2Before, c2Before, err := getBalance(ctx, conn, rb2)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.rebuild_balances($1)`, ledgerUUID)
		assert.NoErr(err)

		d1After, c1After, err := getBalance(ctx, conn, rb1)
		assert.NoErr(err)
		assert.Equal(d1Before, d1After)
		assert.Equal(c1Before, c1After)

		d2After, c2After, err := getBalance(ctx, conn, rb2)
		assert.NoErr(err)
		assert.Equal(d2Before, d2After)
		assert.Equal(c2Before, c2After)
	})
}

func TestConstraintBoundaryEnforcement(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "constraint_boundary_user")
	assert.NoErr(err)

	var ledgerUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Constraint Boundary')`).Scan(&ledgerUUID)
	assert.NoErr(err)

	t.Run("ExactLimitSucceeds_DebitsEqCredits", func(t *testing.T) {
		assert := is_.New(t)

		// account with debits_must_not_exceed_credits
		var constrained, funder string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'DNEC Exact', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Funder DNEC Exact')`,
			ledgerUUID).Scan(&funder)
		assert.NoErr(err)

		// fund: credit the constrained account with 10000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, funder, constrained)
		assert.NoErr(err)

		// debit exactly 10000 — should succeed
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, constrained, funder)
		assert.NoErr(err)
	})

	t.Run("OnePastLimitFails_DebitsExceedCredits", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, funder string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'DNEC Over', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Funder DNEC Over')`,
			ledgerUUID).Scan(&funder)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, funder, constrained)
		assert.NoErr(err)

		// debit 10001 — should fail
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10001)`,
			ledgerUUID, constrained, funder)
		assert.True(err != nil) // exceeds credits
	})

	t.Run("ExactLimitSucceeds_CreditsEqDebits", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, funder string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'CNED Exact', null, false, true)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Funder CNED Exact')`,
			ledgerUUID).Scan(&funder)
		assert.NoErr(err)

		// fund: debit the constrained account with 10000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, constrained, funder)
		assert.NoErr(err)

		// credit exactly 10000 — should succeed
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, funder, constrained)
		assert.NoErr(err)
	})

	t.Run("OnePastLimitFails_CreditsExceedDebits", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, funder string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'CNED Over', null, false, true)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Funder CNED Over')`,
			ledgerUUID).Scan(&funder)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, constrained, funder)
		assert.NoErr(err)

		// credit 10001 — should fail
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10001)`,
			ledgerUUID, funder, constrained)
		assert.True(err != nil) // exceeds debits
	})

	t.Run("PendingHoldReducesAvailableForPost", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Pending Post', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Other Pending Post')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		// fund 10000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		// reserve 6000 (pending hold)
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 6000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err)

		// post 5000 — should fail (pending 6000 + post 5000 = 11000 > 10000)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 5000)`,
			ledgerUUID, constrained, other)
		assert.True(err != nil)
	})

	t.Run("PendingHoldReducesAvailableForReserve", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Pending Reserve', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Other Pending Reserve')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 6000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err)

		// reserve 5000 more — should fail
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 5000)`,
			ledgerUUID, constrained, other)
		assert.True(err != nil)
	})

	t.Run("VoidFreesBalanceForNewTransaction", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Void Free', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Other Void Free')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		// fund 10000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		// spend 10000
		var spendUUID string
		err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, constrained, other).Scan(&spendUUID)
		assert.NoErr(err)

		// void the spend
		_, err = conn.Exec(ctx, `select ledger.void($1)`, spendUUID)
		assert.NoErr(err)

		// spend 10000 again — should succeed (void freed the balance)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err)
	})

	t.Run("ReleaseFreesHoldForNewTransaction", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Release Free', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Other Release Free')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 10000)`,
			ledgerUUID, constrained, other).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.release($1)`, holdUUID)
		assert.NoErr(err)

		// reserve again — should succeed
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 10000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err)
	})

	t.Run("ConstraintCheckedAfterCounterUpdate", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Drain', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Other Drain')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 5000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 3000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err) // ok: 3000 <= 5000

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 2000)`,
			ledgerUUID, constrained, other)
		assert.NoErr(err) // ok: 5000 <= 5000

		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 1)`,
			ledgerUUID, constrained, other)
		assert.True(err != nil) // fail: 5001 > 5000
	})
}

func TestTwoPhaseGuarantees(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "twophase_guarantee_user")
	assert.NoErr(err)

	var ledgerUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Two Phase Guarantees')`).Scan(&ledgerUUID)
	assert.NoErr(err)

	t.Run("PartialCommitReleasesRemainder", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'PCR A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'PCR B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 20000)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1, 12000)`, holdUUID)
		assert.NoErr(err)

		// no pending rows should remain
		var pendingCount int
		err = conn.QueryRow(ctx, `
			select count(*) from data.pending p
			join data.transactions t on t.id = p.transaction_id
			where t.uuid = $1
		`, holdUUID).Scan(&pendingCount)
		assert.NoErr(err)
		assert.Equal(pendingCount, 0)
	})

	t.Run("PartialCommitDoesNotHoldRemainder", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'PDHR A', null, true, false)`,
			ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'PDHR B')`,
			ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		// fund 20000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 20000)`,
			ledgerUUID, a2, a1)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 20000)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1, 10000)`, holdUUID)
		assert.NoErr(err)

		// should be able to reserve 10000 more (remainder was released)
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 10000)`,
			ledgerUUID, a1, a2)
		assert.NoErr(err)
	})

	t.Run("CommitAfterExpireFails", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Expire A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Expire B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 5000, 1)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		time.Sleep(2 * time.Second)

		_, err = conn.Exec(ctx, `select ledger.expire_pending()`)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, holdUUID)
		assert.True(err != nil) // expired, can't commit
	})

	t.Run("ExpireOnlyAffectsTimedOut", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Expire Selective A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Expire Selective B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		// short timeout
		var shortUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 3000, 1)`,
			ledgerUUID, a1, a2).Scan(&shortUUID)
		assert.NoErr(err)

		// long timeout
		var longUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 4000, 300)`,
			ledgerUUID, a1, a2).Scan(&longUUID)
		assert.NoErr(err)

		time.Sleep(2 * time.Second)

		_, err = conn.Exec(ctx, `select ledger.expire_pending()`)
		assert.NoErr(err)

		// short one should be expired
		_, err = conn.Exec(ctx, `select ledger.commit($1)`, shortUUID)
		assert.True(err != nil)

		// long one should still be committable
		_, err = conn.Exec(ctx, `select ledger.commit($1)`, longUUID)
		assert.NoErr(err)
	})

	t.Run("DoubleCommitFails", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'DblCommit A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'DblCommit B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 5000)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1)`, holdUUID)
		assert.True(err != nil) // already committed
	})

	t.Run("DoubleReleaseFails", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'DblRelease A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'DblRelease B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 5000)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.release($1)`, holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.release($1)`, holdUUID)
		assert.True(err != nil) // already released
	})

	t.Run("CommitZeroFails", func(t *testing.T) {
		assert := is_.New(t)

		var a1, a2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Zero Commit A')`, ledgerUUID).Scan(&a1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Zero Commit B')`, ledgerUUID).Scan(&a2)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 5000)`,
			ledgerUUID, a1, a2).Scan(&holdUUID)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.commit($1, 0)`, holdUUID)
		assert.True(err != nil) // zero amount
	})

	t.Run("MultipleReservesAgainstSameConstrainedAccount", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Multi Reserve', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Multi Other')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		// fund 10000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 3000)`, ledgerUUID, constrained, other)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 3000)`, ledgerUUID, constrained, other)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 3000)`, ledgerUUID, constrained, other)
		assert.NoErr(err) // 9000 <= 10000

		_, err = conn.Exec(ctx, `select ledger.reserve($1, $2, $3, 2000)`, ledgerUUID, constrained, other)
		assert.True(err != nil) // 11000 > 10000
	})
}

func TestAtomicity(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "atomicity_test_user")
	assert.NoErr(err)

	var ledgerUUID, acctA, acctB string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Atomicity Test')`).Scan(&ledgerUUID)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom A')`, ledgerUUID).Scan(&acctA)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom B')`, ledgerUUID).Scan(&acctB)
	assert.NoErr(err)

	t.Run("BatchRollbackLeavesNoTransactions", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		// 3rd entry has invalid amount (0)
		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_transactions($1, '[
				{"debit": "%s", "credit": "%s", "amount": 1000},
				{"debit": "%s", "credit": "%s", "amount": 2000},
				{"debit": "%s", "credit": "%s", "amount": 0}
			]'::jsonb)`, acctA, acctB, acctA, acctB, acctA, acctB), ledgerUUID)
		assert.True(err != nil)

		after, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after, before) // no partial inserts
	})

	t.Run("BatchRollbackLeavesCountersUnchanged", func(t *testing.T) {
		assert := is_.New(t)

		dBefore, cBefore, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_transactions($1, '[
				{"debit": "%s", "credit": "%s", "amount": 5000},
				{"debit": "%s", "credit": "%s", "amount": 0}
			]'::jsonb)`, acctA, acctB, acctA, acctB), ledgerUUID)
		assert.True(err != nil)

		dAfter, cAfter, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)
		assert.Equal(dBefore, dAfter)
		assert.Equal(cBefore, cAfter)
	})

	t.Run("BatchRollbackLeavesNoBalanceHistory", func(t *testing.T) {
		assert := is_.New(t)

		before, err := countBalances(ctx, conn)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_transactions($1, '[
				{"debit": "%s", "credit": "%s", "amount": 3000},
				{"debit": "%s", "credit": "%s", "amount": 0}
			]'::jsonb)`, acctA, acctB, acctA, acctB), ledgerUUID)
		assert.True(err != nil)

		after, err := countBalances(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after, before)
	})

	t.Run("LinkedRollbackLeavesNoTransactions", func(t *testing.T) {
		assert := is_.New(t)

		// create clearing account for linked
		var clearing string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom Clearing')`, ledgerUUID).Scan(&clearing)
		assert.NoErr(err)

		before, err := countTransactions(ctx, conn)
		assert.NoErr(err)

		// 2nd leg has invalid amount
		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 5000},
				{"debit": "%s", "credit": "%s", "amount": 0}
			]'::jsonb)`, acctA, clearing, clearing, acctB), ledgerUUID)
		assert.True(err != nil)

		after, err := countTransactions(ctx, conn)
		assert.NoErr(err)
		assert.Equal(after, before)
	})

	t.Run("LinkedRollbackLeavesCountersUnchanged", func(t *testing.T) {
		assert := is_.New(t)

		var clearing2 string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom Clearing 2')`, ledgerUUID).Scan(&clearing2)
		assert.NoErr(err)

		dBefore, cBefore, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 7000},
				{"debit": "%s", "credit": "%s", "amount": 0}
			]'::jsonb)`, acctA, clearing2, clearing2, acctB), ledgerUUID)
		assert.True(err != nil)

		dAfter, cAfter, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)
		assert.Equal(dBefore, dAfter)
		assert.Equal(cBefore, cAfter)
	})

	t.Run("ConstraintFailureRollsBackEntireBatch", func(t *testing.T) {
		assert := is_.New(t)

		var constrained, other string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom Constrained', null, true, false)`,
			ledgerUUID).Scan(&constrained)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Atom Other')`,
			ledgerUUID).Scan(&other)
		assert.NoErr(err)

		// fund 1000
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, 1000)`,
			ledgerUUID, other, constrained)
		assert.NoErr(err)

		dBefore, cBefore, err := getBalance(ctx, conn, constrained)
		assert.NoErr(err)

		// batch: 500 (ok alone) + 600 (would exceed). entire batch should fail.
		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_transactions($1, '[
				{"debit": "%s", "credit": "%s", "amount": 500},
				{"debit": "%s", "credit": "%s", "amount": 600}
			]'::jsonb)`, constrained, other, constrained, other), ledgerUUID)
		assert.True(err != nil)

		dAfter, cAfter, err := getBalance(ctx, conn, constrained)
		assert.NoErr(err)
		assert.Equal(dBefore, dAfter)
		assert.Equal(cBefore, cAfter)
	})

	t.Run("CorrectIsAtomicOnFailure", func(t *testing.T) {
		assert := is_.New(t)

		var src, dst, closed string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Correct Src')`, ledgerUUID).Scan(&src)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Correct Dst')`, ledgerUUID).Scan(&dst)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Correct Closed')`, ledgerUUID).Scan(&closed)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, `select ledger.close_account($1)`, closed)
		assert.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 5000)`,
			ledgerUUID, src, dst).Scan(&txUUID)
		assert.NoErr(err)

		dBefore, cBefore, err := getBalance(ctx, conn, src)
		assert.NoErr(err)

		// correct to a closed account — should fail
		_, err = conn.Exec(ctx, `select ledger.correct($1, $2, $3, 5000)`, txUUID, src, closed)
		assert.True(err != nil)

		// counters should be unchanged (reversal rolled back too)
		dAfter, cAfter, err := getBalance(ctx, conn, src)
		assert.NoErr(err)
		assert.Equal(dBefore, dAfter)
		assert.Equal(cBefore, cAfter)
	})
}

func TestUserIsolation(t *testing.T) {
	ctx := context.Background()

	// two separate connections, two different users
	connA, err := pgx.Connect(ctx, testDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connA.Close(ctx) })

	connB, err := pgx.Connect(ctx, testDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connB.Close(ctx) })

	userA := "isolation_user_a"
	userB := "isolation_user_b"

	if err := setTestUserContext(ctx, connA, userA); err != nil {
		t.Fatal(err)
	}
	if err := setTestUserContext(ctx, connB, userB); err != nil {
		t.Fatal(err)
	}

	// user A creates a ledger with accounts and transactions
	var ledgerA, acctA1, acctA2, txA string
	connA.QueryRow(ctx, `select ledger.create_ledger('Shared Name')`).Scan(&ledgerA)
	connA.QueryRow(ctx, `select ledger.create_account($1, 'Checking')`, ledgerA).Scan(&acctA1)
	connA.QueryRow(ctx, `select ledger.create_account($1, 'Savings')`, ledgerA).Scan(&acctA2)
	connA.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 50000)`,
		ledgerA, acctA1, acctA2).Scan(&txA)

	t.Run("TwoUsersCanCreateSameNameLedger", func(t *testing.T) {
		assert := is_.New(t)

		var ledgerB string
		err := connB.QueryRow(ctx, `select ledger.create_ledger('Shared Name')`).Scan(&ledgerB)
		assert.NoErr(err)
		assert.True(ledgerA != ledgerB) // different UUIDs
	})

	t.Run("UserCannotSeeOtherUsersLedger", func(t *testing.T) {
		assert := is_.New(t)

		_, err := connB.Exec(ctx, `select * from ledger.get_accounts($1)`, ledgerA)
		assert.True(err != nil) // not found
	})

	t.Run("UserCannotSeeOtherUsersAccounts", func(t *testing.T) {
		assert := is_.New(t)

		// ledger API function enforces user isolation via user_data check
		_, err := connB.Exec(ctx, `select * from ledger.get_balance($1)`, acctA1)
		assert.True(err != nil) // account not found for user B
	})

	t.Run("UserCannotSeeOtherUsersTransactions", func(t *testing.T) {
		assert := is_.New(t)

		// user B can't void user A's transaction — function checks user_data
		_, err := connB.Exec(ctx, `select ledger.void($1)`, txA)
		assert.True(err != nil) // transaction not found
	})

	t.Run("UserCannotSeeOtherUsersBalances", func(t *testing.T) {
		assert := is_.New(t)

		// user B can't get history for user A's account
		_, err := connB.Exec(ctx, `select * from ledger.get_history($1)`, acctA1)
		assert.True(err != nil) // account not found
	})

	t.Run("UserCannotVoidOtherUsersTransaction", func(t *testing.T) {
		assert := is_.New(t)

		_, err := connB.Exec(ctx, `select ledger.void($1)`, txA)
		assert.True(err != nil) // not found
	})

	t.Run("UserCannotCorrectOtherUsersTransaction", func(t *testing.T) {
		assert := is_.New(t)

		_, err := connB.Exec(ctx, `select ledger.correct($1, null, null, 99999)`, txA)
		assert.True(err != nil) // not found
	})

	t.Run("UserCannotSeeOtherUsersPending", func(t *testing.T) {
		assert := is_.New(t)

		// user A creates a pending hold
		var holdUUID string
		err := connA.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 1000)`,
			ledgerA, acctA1, acctA2).Scan(&holdUUID)
		if err != nil {
			t.Skip("reserve failed, skipping pending isolation test")
		}

		// user B can't commit user A's pending transaction
		_, err = connB.Exec(ctx, `select ledger.commit($1)`, holdUUID)
		assert.True(err != nil) // not found for user B
	})
}

func TestLinkedTransferGuarantees(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "linked_guarantee_user")
	assert.NoErr(err)

	var ledgerUUID, checking, savings, clearing string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Linked Guarantees')`).Scan(&ledgerUUID)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'LG Checking')`, ledgerUUID).Scan(&checking)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'LG Savings')`, ledgerUUID).Scan(&savings)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'LG Clearing')`, ledgerUUID).Scan(&clearing)
	assert.NoErr(err)

	// make clearing internal
	_, err = conn.Exec(ctx, `update data.accounts set visibility = 'internal' where uuid = $1`, clearing)
	assert.NoErr(err)

	t.Run("ClearingAccountAlwaysNetsToZero", func(t *testing.T) {
		assert := is_.New(t)

		_, err := conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 10000, "description": "To savings"},
				{"debit": "%s", "credit": "%s", "amount": 10000, "description": "From checking"}
			]'::jsonb)`, checking, clearing, clearing, savings), ledgerUUID)
		assert.NoErr(err)

		d, c, err := getBalance(ctx, conn, clearing)
		assert.NoErr(err)
		assert.Equal(d, c) // nets to zero
	})

	t.Run("LinkIdIsSharedAcrossGroup", func(t *testing.T) {
		assert := is_.New(t)

		var uuids []string
		rows, err := conn.Query(ctx, fmt.Sprintf(`
			select unnest(ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 5000},
				{"debit": "%s", "credit": "%s", "amount": 5000}
			]'::jsonb))`, checking, clearing, clearing, savings), ledgerUUID)
		assert.NoErr(err)
		defer rows.Close()
		for rows.Next() {
			var u string
			assert.NoErr(rows.Scan(&u))
			uuids = append(uuids, u)
		}
		assert.NoErr(rows.Err())
		assert.Equal(len(uuids), 2)

		var linkID1, linkID2 *int64
		err = conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuids[0]).Scan(&linkID1)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuids[1]).Scan(&linkID2)
		assert.NoErr(err)

		assert.True(linkID1 != nil)
		assert.True(linkID2 != nil)
		assert.Equal(*linkID1, *linkID2) // same link_id
	})

	t.Run("LinkIdIsUniquePerGroup", func(t *testing.T) {
		assert := is_.New(t)

		var uuid1, uuid2 string

		rows1, err := conn.Query(ctx, fmt.Sprintf(`
			select unnest(ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 1000},
				{"debit": "%s", "credit": "%s", "amount": 1000}
			]'::jsonb))`, checking, clearing, clearing, savings), ledgerUUID)
		assert.NoErr(err)
		for rows1.Next() {
			rows1.Scan(&uuid1)
		}
		rows1.Close()

		rows2, err := conn.Query(ctx, fmt.Sprintf(`
			select unnest(ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 2000},
				{"debit": "%s", "credit": "%s", "amount": 2000}
			]'::jsonb))`, checking, clearing, clearing, savings), ledgerUUID)
		assert.NoErr(err)
		for rows2.Next() {
			rows2.Scan(&uuid2)
		}
		rows2.Close()

		var link1, link2 int64
		conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuid1).Scan(&link1)
		conn.QueryRow(ctx, `select link_id from data.transactions where uuid = $1`, uuid2).Scan(&link2)

		assert.True(link1 != link2) // different groups
	})

	t.Run("HistoryResolvesCounterpartyThroughClearing", func(t *testing.T) {
		assert := is_.New(t)

		// create fresh accounts for clean history
		var ch, sv, cl string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Resolve Checking')`, ledgerUUID).Scan(&ch)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Resolve Savings')`, ledgerUUID).Scan(&sv)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Resolve Clearing')`, ledgerUUID).Scan(&cl)
		assert.NoErr(err)
		_, err = conn.Exec(ctx, `update data.accounts set visibility = 'internal' where uuid = $1`, cl)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 8000, "description": "Transfer out"},
				{"debit": "%s", "credit": "%s", "amount": 8000, "description": "Transfer in"}
			]'::jsonb)`, ch, cl, cl, sv), ledgerUUID)
		assert.NoErr(err)

		// checking's history should show savings as counterparty, not clearing
		var counterparty string
		err = conn.QueryRow(ctx, `
			select counterparty from ledger.get_history($1) limit 1
		`, ch).Scan(&counterparty)
		assert.NoErr(err)
		assert.Equal(counterparty, "Resolve Savings") // resolved through clearing
	})

	t.Run("LinkedDoesNotAllowSingleLeg", func(t *testing.T) {
		assert := is_.New(t)

		_, err := conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 1000}
			]'::jsonb)`, checking, savings), ledgerUUID)
		assert.True(err != nil) // at least 2 required
	})

	t.Run("LinkedCountersCorrectForBothSides", func(t *testing.T) {
		assert := is_.New(t)

		var lc, ls, lcl string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'LC Checking')`, ledgerUUID).Scan(&lc)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'LC Savings')`, ledgerUUID).Scan(&ls)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'LC Clearing')`, ledgerUUID).Scan(&lcl)
		assert.NoErr(err)

		_, err = conn.Exec(ctx, fmt.Sprintf(`
			select ledger.post_linked($1, '[
				{"debit": "%s", "credit": "%s", "amount": 30000},
				{"debit": "%s", "credit": "%s", "amount": 30000}
			]'::jsonb)`, lc, lcl, lcl, ls), ledgerUUID)
		assert.NoErr(err)

		dCh, cCh, err := getBalance(ctx, conn, lc)
		assert.NoErr(err)
		assert.Equal(dCh, int64(30000))
		assert.Equal(cCh, int64(0))

		dSv, cSv, err := getBalance(ctx, conn, ls)
		assert.NoErr(err)
		assert.Equal(dSv, int64(0))
		assert.Equal(cSv, int64(30000))

		dCl, cCl, err := getBalance(ctx, conn, lcl)
		assert.NoErr(err)
		assert.Equal(dCl, cCl) // clearing nets to zero
	})
}

func TestEdgeCases(t *testing.T) {
	assert := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	assert.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "edge_case_user")
	assert.NoErr(err)

	var ledgerUUID, acctA, acctB string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Edge Cases')`).Scan(&ledgerUUID)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Edge A')`, ledgerUUID).Scan(&acctA)
	assert.NoErr(err)
	err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Edge B')`, ledgerUUID).Scan(&acctB)
	assert.NoErr(err)

	t.Run("DoubleVoid", func(t *testing.T) {
		assert := is_.New(t)

		var txUUID string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 10000)`,
			ledgerUUID, acctA, acctB).Scan(&txUUID)
		assert.NoErr(err)

		// first void creates reversal
		var reversalUUID string
		err = conn.QueryRow(ctx, `select ledger.void($1)`, txUUID).Scan(&reversalUUID)
		assert.NoErr(err)

		// void the reversal — should succeed (it's a valid posted transaction)
		_, err = conn.Exec(ctx, `select ledger.void($1)`, reversalUUID)
		assert.NoErr(err)

		// net effect: original + reversal + reversal-of-reversal = back to original
		dA, cA, err := getBalance(ctx, conn, acctA)
		assert.NoErr(err)
		// acctA: debited 10000 (orig) + credited 10000 (void) + debited 10000 (void of void)
		assert.Equal(dA, int64(20000))
		assert.Equal(cA, int64(10000))
		// net = 10000 (same as original effect)
	})

	t.Run("OperationsOnNonexistentUUIDs", func(t *testing.T) {
		assert := is_.New(t)

		_, err := conn.Exec(ctx, `select ledger.void('nonexistent')`)
		assert.True(err != nil)

		_, err = conn.Exec(ctx, `select ledger.correct('nonexistent')`)
		assert.True(err != nil)

		_, err = conn.Exec(ctx, `select ledger.commit('nonexistent')`)
		assert.True(err != nil)

		_, err = conn.Exec(ctx, `select ledger.release('nonexistent')`)
		assert.True(err != nil)

		_, err = conn.Exec(ctx, `select * from ledger.get_balance('nonexistent')`)
		assert.True(err != nil)

		_, err = conn.Exec(ctx, `select * from ledger.get_history('nonexistent')`)
		assert.True(err != nil)
	})

	t.Run("LargeAmountTransaction", func(t *testing.T) {
		assert := is_.New(t)

		var la, lb string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Large A')`, ledgerUUID).Scan(&la)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Large B')`, ledgerUUID).Scan(&lb)
		assert.NoErr(err)

		largeAmount := int64(9_000_000_000_000_000)
		_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, $4)`,
			ledgerUUID, la, lb, largeAmount)
		assert.NoErr(err)

		d, c, err := getBalance(ctx, conn, la)
		assert.NoErr(err)
		assert.Equal(d, largeAmount)
		assert.Equal(c, int64(0))
	})

	t.Run("ManyTransactionsCountersStayCorrect", func(t *testing.T) {
		assert := is_.New(t)

		var ma, mb string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Many A')`, ledgerUUID).Scan(&ma)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Many B')`, ledgerUUID).Scan(&mb)
		assert.NoErr(err)

		var expectedSum int64
		for i := 1; i <= 100; i++ {
			amount := int64(i * 100)
			_, err = conn.Exec(ctx, `select ledger.post_transaction($1, $2, $3, $4)`,
				ledgerUUID, ma, mb, amount)
			assert.NoErr(err)
			expectedSum += amount
		}

		d, c, err := getBalance(ctx, conn, ma)
		assert.NoErr(err)
		assert.Equal(d, expectedSum) // 100 * 101 / 2 * 100 = 505000
		assert.Equal(c, int64(0))
	})

	t.Run("IdempotencyKeyIsolatedByUser", func(t *testing.T) {
		assert := is_.New(t)

		// user A posts with a key
		var uuidA string
		err := conn.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 1000, current_date, 'test', 'shared_key')`,
			ledgerUUID, acctA, acctB).Scan(&uuidA)
		assert.NoErr(err)

		// user B with same key should create a different transaction
		connB, err := pgx.Connect(ctx, testDSN)
		assert.NoErr(err)
		defer connB.Close(ctx)
		err = setTestUserContext(ctx, connB, "edge_case_user_b")
		assert.NoErr(err)

		var ledgerB, aB1, aB2 string
		err = connB.QueryRow(ctx, `select ledger.create_ledger('Edge B Ledger')`).Scan(&ledgerB)
		assert.NoErr(err)
		err = connB.QueryRow(ctx, `select ledger.create_account($1, 'B1')`, ledgerB).Scan(&aB1)
		assert.NoErr(err)
		err = connB.QueryRow(ctx, `select ledger.create_account($1, 'B2')`, ledgerB).Scan(&aB2)
		assert.NoErr(err)

		var uuidB string
		err = connB.QueryRow(ctx, `select ledger.post_transaction($1, $2, $3, 1000, current_date, 'test', 'shared_key')`,
			ledgerB, aB1, aB2).Scan(&uuidB)
		assert.NoErr(err)

		assert.True(uuidA != uuidB) // different transactions despite same key
	})

	t.Run("ReserveWithZeroTimeoutGetsNullTimeout", func(t *testing.T) {
		assert := is_.New(t)

		var ra, rb string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'ZeroTO A')`, ledgerUUID).Scan(&ra)
		assert.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'ZeroTO B')`, ledgerUUID).Scan(&rb)
		assert.NoErr(err)

		var holdUUID string
		err = conn.QueryRow(ctx, `select ledger.reserve($1, $2, $3, 5000, 0)`,
			ledgerUUID, ra, rb).Scan(&holdUUID)
		assert.NoErr(err)

		var timeoutAt *time.Time
		err = conn.QueryRow(ctx, `select timeout_at from data.transactions where uuid = $1`,
			holdUUID).Scan(&timeoutAt)
		assert.NoErr(err)
		assert.True(timeoutAt == nil) // null timeout

		// expire_pending should not expire it
		_, err = conn.Exec(ctx, `select ledger.expire_pending()`)
		assert.NoErr(err)

		// should still be committable
		_, err = conn.Exec(ctx, `select ledger.commit($1)`, holdUUID)
		assert.NoErr(err)
	})
}

func TestAccountAndTransactionCode(t *testing.T) {
	is := is_.New(t)
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, testDSN)
	is.NoErr(err)
	t.Cleanup(func() { conn.Close(ctx) })

	err = setTestUserContext(ctx, conn, "code_field_user")
	is.NoErr(err)

	var ledgerUUID string
	err = conn.QueryRow(ctx, `select ledger.create_ledger('Code Field Test')`).Scan(&ledgerUUID)
	is.NoErr(err)

	t.Run("AccountCodeDefaultsToZero", func(t *testing.T) {
		is := is_.New(t)

		// create account without p_code — should default to 0
		var acctUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Default-Code')`, ledgerUUID).Scan(&acctUUID)
		is.NoErr(err)

		var code int16
		err = conn.QueryRow(ctx, `select code from data.accounts where uuid = $1`, acctUUID).Scan(&code)
		is.NoErr(err)
		is.Equal(code, int16(0))
	})

	t.Run("AccountCodeStoredAndReturned", func(t *testing.T) {
		is := is_.New(t)

		// create with explicit code via named param
		var acctUUID string
		err := conn.QueryRow(ctx, `
			select ledger.create_account(
				p_ledger_uuid := $1,
				p_name := 'Tagged-Account',
				p_code := 42::smallint
			)
		`, ledgerUUID).Scan(&acctUUID)
		is.NoErr(err)

		// stored on row
		var code int16
		err = conn.QueryRow(ctx, `select code from data.accounts where uuid = $1`, acctUUID).Scan(&code)
		is.NoErr(err)
		is.Equal(code, int16(42))

		// returned by get_accounts
		var retCode int16
		err = conn.QueryRow(ctx, `
			select code from ledger.get_accounts($1) where account_uuid = $2
		`, ledgerUUID, acctUUID).Scan(&retCode)
		is.NoErr(err)
		is.Equal(retCode, int16(42))
	})

	t.Run("TransactionCodeDefaultsToZero", func(t *testing.T) {
		is := is_.New(t)

		var srcUUID, dstUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Src-Zero')`, ledgerUUID).Scan(&srcUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Dst-Zero')`, ledgerUUID).Scan(&dstUUID)
		is.NoErr(err)

		// post without p_code
		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction($1, $2, $3, 500, '2026-04-01', 'default code')
		`, ledgerUUID, srcUUID, dstUUID).Scan(&txUUID)
		is.NoErr(err)

		var code int16
		err = conn.QueryRow(ctx, `select code from data.transactions where uuid = $1`, txUUID).Scan(&code)
		is.NoErr(err)
		is.Equal(code, int16(0))
	})

	t.Run("TransactionCodeStored", func(t *testing.T) {
		is := is_.New(t)

		var srcUUID, dstUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Src-Code')`, ledgerUUID).Scan(&srcUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Dst-Code')`, ledgerUUID).Scan(&dstUUID)
		is.NoErr(err)

		var txUUID string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction(
				p_ledger_uuid := $1,
				p_debit_account_uuid := $2,
				p_credit_account_uuid := $3,
				p_amount := 500,
				p_code := 7::smallint
			)
		`, ledgerUUID, srcUUID, dstUUID).Scan(&txUUID)
		is.NoErr(err)

		var code int16
		err = conn.QueryRow(ctx, `select code from data.transactions where uuid = $1`, txUUID).Scan(&code)
		is.NoErr(err)
		is.Equal(code, int16(7))
	})

	t.Run("CodeCanBeFilteredViaIndex", func(t *testing.T) {
		is := is_.New(t)

		// create several accounts with distinct codes
		for _, tc := range []struct {
			name string
			code int16
		}{
			{"Filter-A", 100},
			{"Filter-B", 100},
			{"Filter-C", 200},
		} {
			_, err := conn.Exec(ctx, `
				select ledger.create_account(
					p_ledger_uuid := $1, p_name := $2, p_code := $3
				)
			`, ledgerUUID, tc.name, tc.code)
			is.NoErr(err)
		}

		// filter by code
		var count int
		err := conn.QueryRow(ctx, `
			select count(*) from data.accounts
			where ledger_id = (select id from data.ledgers where uuid = $1)
			  and code = 100
		`, ledgerUUID).Scan(&count)
		is.NoErr(err)
		is.Equal(count, 2)
	})

	t.Run("IdempotencyIgnoresCodeOnRetry", func(t *testing.T) {
		is := is_.New(t)

		var srcUUID, dstUUID string
		err := conn.QueryRow(ctx, `select ledger.create_account($1, 'Src-Idem')`, ledgerUUID).Scan(&srcUUID)
		is.NoErr(err)
		err = conn.QueryRow(ctx, `select ledger.create_account($1, 'Dst-Idem')`, ledgerUUID).Scan(&dstUUID)
		is.NoErr(err)

		// first post with code=11
		var uuid1 string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction(
				p_ledger_uuid := $1, p_debit_account_uuid := $2, p_credit_account_uuid := $3,
				p_amount := 100, p_idempotency_key := 'code_key_1', p_code := 11::smallint
			)
		`, ledgerUUID, srcUUID, dstUUID).Scan(&uuid1)
		is.NoErr(err)

		// retry with different code — should return original uuid, original code preserved
		var uuid2 string
		err = conn.QueryRow(ctx, `
			select ledger.post_transaction(
				p_ledger_uuid := $1, p_debit_account_uuid := $2, p_credit_account_uuid := $3,
				p_amount := 100, p_idempotency_key := 'code_key_1', p_code := 99::smallint
			)
		`, ledgerUUID, srcUUID, dstUUID).Scan(&uuid2)
		is.NoErr(err)
		is.Equal(uuid1, uuid2)

		var stored int16
		err = conn.QueryRow(ctx, `select code from data.transactions where uuid = $1`, uuid1).Scan(&stored)
		is.NoErr(err)
		is.Equal(stored, int16(11)) // original code preserved
	})
}
