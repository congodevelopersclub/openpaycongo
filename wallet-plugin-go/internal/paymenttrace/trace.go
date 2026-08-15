// Package paymenttrace produces bounded, secret-free payment processing evidence.
package paymenttrace

import ("context"; "errors"; "sort"; "time")
const MaxRows=100
const MaxTimeout=5*time.Second
type Query struct{ TenantID string; Limit int; Timeout time.Duration }
type Record struct{ TenantID,EventID,EventDigest,AcknowledgementCursor,ProjectionRevision,MigrationID,MigrationChecksum,ResultCode string; Ordering,DurationMS int64 }
type Port interface{ ReadTrace(context.Context,Query)([]Record,error) }
type Service struct{ Port Port }
func(s Service) Trace(ctx context.Context,q Query)([]Record,error){if s.Port==nil||q.TenantID==""||q.Limit<1||q.Limit>MaxRows||q.Timeout<1||q.Timeout>MaxTimeout{return nil,errors.New("invalid bounded trace query")};ctx,cancel:=context.WithTimeout(ctx,q.Timeout);defer cancel();rows,err:=s.Port.ReadTrace(ctx,q);if err!=nil{return nil,err};if len(rows)>q.Limit{return nil,errors.New("trace row bound exceeded")};for _,r:=range rows{if r.TenantID!=q.TenantID||r.EventID==""||len(r.EventDigest)!=64||r.MigrationID==""||len(r.MigrationChecksum)!=64||r.ProjectionRevision==""||r.ResultCode==""||r.DurationMS<0{return nil,errors.New("invalid trace evidence")}};sort.Slice(rows,func(i,j int)bool{if rows[i].Ordering==rows[j].Ordering{return rows[i].EventID<rows[j].EventID};return rows[i].Ordering<rows[j].Ordering});return rows,nil}
