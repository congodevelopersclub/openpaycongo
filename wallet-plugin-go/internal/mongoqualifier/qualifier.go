package mongoqualifier
import "errors"
type Evidence struct{WritablePrimary,MajorityWriteConcern,Transactions,RetryableWrites,ClockHealthy,TopologyKnown,RequiredIndexes,RestartRecovery bool;TopologyID string}
type Result struct{Ready bool;TopologyID string;Reason string}
func Qualify(e Evidence)Result{if e.TopologyID==""||!e.TopologyKnown{return Result{Reason:"unknown topology"}};for _,v:=range []bool{e.WritablePrimary,e.MajorityWriteConcern,e.Transactions,e.RetryableWrites,e.ClockHealthy,e.RequiredIndexes,e.RestartRecovery}{if !v{return Result{TopologyID:e.TopologyID,Reason:"required replica-set evidence missing"}}};return Result{Ready:true,TopologyID:e.TopologyID,Reason:"qualified"}}
func Require(e Evidence)error{if r:=Qualify(e);!r.Ready{return errors.New(r.Reason)};return nil}
