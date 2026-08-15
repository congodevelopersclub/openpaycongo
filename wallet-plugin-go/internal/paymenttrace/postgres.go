package paymenttrace

import("context";"database/sql";"fmt";_ "github.com/jackc/pgx/v5/stdlib")
type PostgresPort struct{db *sql.DB}
func OpenPostgres(ctx context.Context,dsn string)(*PostgresPort,error){db,err:=sql.Open("pgx",dsn);if err!=nil{return nil,err};ctx,c:=context.WithTimeout(ctx,MaxTimeout);defer c();if err=db.PingContext(ctx);err!=nil{db.Close();return nil,err};return &PostgresPort{db},nil}
func(p *PostgresPort)Close()error{return p.db.Close()}
func(p *PostgresPort)ReadTrace(ctx context.Context,q Query)([]Record,error){ctx,c:=context.WithTimeout(ctx,q.Timeout);defer c();rows,err:=p.db.QueryContext(ctx,`SELECT tenant_id,event_id,event_digest,ack_cursor,projection_revision,migration_id,migration_checksum,result_code,ordering,duration_ms FROM payment_trace_metadata WHERE tenant_id=$1 ORDER BY ordering,event_id LIMIT $2`,q.TenantID,q.Limit);if err!=nil{return nil,err};defer rows.Close();var out []Record;for rows.Next(){var r Record;if err:=rows.Scan(&r.TenantID,&r.EventID,&r.EventDigest,&r.AcknowledgementCursor,&r.ProjectionRevision,&r.MigrationID,&r.MigrationChecksum,&r.ResultCode,&r.Ordering,&r.DurationMS);err!=nil{return nil,err};out=append(out,r)};if err:=rows.Err();err!=nil{return nil,err};return out,nil}
func MigrationMismatch(expected,actual string)error{if expected!=actual{return fmt.Errorf("migration checksum mismatch")};return nil}
