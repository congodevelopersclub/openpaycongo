package mongoqualifier
import"testing"
func TestQualifierFailsClosedAndEmitsOnlyTopologyMetadata(t *testing.T){good:=Evidence{true,true,true,true,true,true,true,true,"rs0-primary"};r:=Qualify(good);if !r.Ready||r.TopologyID!="rs0-primary"{t.Fatal(r)};for _,bad:=range []Evidence{{},{WritablePrimary:true,TopologyID:"rs0-primary"},{WritablePrimary:true,MajorityWriteConcern:true,Transactions:true,RetryableWrites:true,ClockHealthy:true,TopologyKnown:true,RequiredIndexes:true,TopologyID:"rs0-primary"}}{if Qualify(bad).Ready{t.Fatal("must fail closed")}}}
