package paymenttrace
import("context";"os";"testing";"time")
func TestMySQLPortScopesAndOrders(t *testing.T){dsn:=os.Getenv("PAYMENT_TRACE_MYSQL_DSN");if dsn==""{t.Skip("set PAYMENT_TRACE_MYSQL_DSN for task-owned MySQL integration")};p,e:=OpenMySQL(context.Background(),dsn);if e!=nil{t.Fatal(e)};defer p.Close();rows,e:=Service{Port:p}.Trace(context.Background(),Query{TenantID:"tenant-a",Limit:2,Timeout:time.Second});if e!=nil||len(rows)!=2||rows[0].EventID!="event-a"{t.Fatalf("rows=%#v err=%v",rows,e)}}
