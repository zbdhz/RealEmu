// Controlled MAC/PHY reference for TestHidden16.bsv, not the missing Case2 source.
// PacketSocket carries 1028 bytes (1000 credited UDP payload + 28 IP/UDP bytes).
// LLC8 + non-QoS MAC24 + FCS4 makes the same 1064-byte PSDU as Bluesim.
#include "ns3/core-module.h"
#include "ns3/network-module.h"
#include "ns3/mobility-module.h"
#include "ns3/wifi-module.h"
#include "ns3/propagation-module.h"
#include <algorithm>
#include <iostream>
#include <set>
#include <vector>
using namespace ns3;
namespace {
Time warm, endMeasure;
uint64_t received = 0;
std::set<uint64_t> dataRates, controlRates;
std::vector<Ptr<Socket>> sockets;
// Optional observation only: retain TX intervals and inspect successful center RXs.
// This does not change the reference error model, scheduling or packet delivery.
bool auditPhy = false;
struct AirInterval { unsigned node; uint16_t sequence; Time start, end; bool data; };
std::vector<AirInterval> air;
std::vector<Mac48Address> addresses;
uint64_t auditGood = 0, auditOverlap = 0, auditPayloadOverlap = 0;
unsigned auditCwEvents = 0;
void Cw(unsigned node, uint32_t value, uint8_t) {
    if (node == 1 && auditCwEvents++ < 12)
        std::cout << "NS3_CW_EVENT node=1 time_us=" << Simulator::Now().GetMicroSeconds()
                  << " cw=" << value << "\n";
}
void RxOk(Ptr<const Packet> packet, double, WifiMode, WifiPreamble) {
    WifiMacHeader header; packet->PeekHeader(header);
    auto now = Simulator::Now();
    if (!header.IsData() || now < warm || now >= endMeasure) return;
    auto sender = std::find(addresses.begin(), addresses.end(), header.GetAddr2()) - addresses.begin();
    auto desired = std::find_if(air.rbegin(), air.rend(), [&](const auto& e) {
        return e.node == sender && e.sequence == header.GetSequenceNumber() && e.end == now;
    });
    NS_ABORT_MSG_IF(desired == air.rend(), "audit cannot match DATA air interval");
    bool overlap = false, payloadOverlap = false;
    for (const auto& e : air) if (e.node != sender && e.node != 0) {
        overlap |= e.start < now && e.end > desired->start;
        payloadOverlap |= e.start < now && e.end > desired->start + MicroSeconds(20);
    }
    ++auditGood; auditOverlap += overlap; auditPayloadOverlap += payloadOverlap;
}
void Receive(Ptr<Socket> socket) {
    while (auto p = socket->Recv()) {
        NS_ABORT_MSG_IF(p->GetSize() != 1028, "unexpected application packet size");
        if (Simulator::Now() >= warm && Simulator::Now() < endMeasure) ++received;
    }
}
void Send(unsigned i) {
    if (Simulator::Now() >= endMeasure) return;
    NS_ABORT_MSG_IF(sockets[i]->Send(Create<Packet>(1028)) < 0, "PacketSocket send failed");
    Simulator::Schedule(MicroSeconds(80), &Send, i);
}
void Tx(unsigned node, WifiConstPsduMap psdus, WifiTxVector vector, double) {
    auto psdu = psdus.begin()->second;
    auto rate = vector.GetMode().GetDataRate(vector);
    if (psdu->GetHeader(0).IsData()) {
        NS_ABORT_MSG_IF(psdu->GetSize() != 1064, "DATA PSDU length mismatch");
        dataRates.insert(rate);
    }
    else controlRates.insert(rate);
    if (auditPhy) air.push_back({node, psdu->GetHeader(0).GetSequenceNumber(), Simulator::Now(),
        Simulator::Now() + WifiPhy::CalculateTxDuration(psdus, vector, WIFI_PHY_BAND_5GHZ),
        psdu->GetHeader(0).IsData()});
}
}
int main(int argc, char** argv) {
    uint32_t senders = 15, run = 1, warmUs = 2000, measureUs = 10000;
    bool rts = false;
    CommandLine cmd(__FILE__);
    cmd.AddValue("senders", "Hidden senders, excluding receiver", senders);
    cmd.AddValue("rts", "RTS/CTS enabled", rts);
    cmd.AddValue("run", "Independent ns-3 random stream run", run);
    cmd.AddValue("warmUs", "Warmup in microseconds", warmUs);
    cmd.AddValue("measureUs", "Receive measurement window in microseconds", measureUs);
    cmd.AddValue("auditPhy", "Count successful DATA with overlapping strong air signals", auditPhy);
    cmd.Parse(argc, argv);
    NS_ABORT_MSG_IF(senders < 1 || senders > 15, "16 total nodes permit 1..15 senders");
    RngSeedManager::SetSeed(12345); RngSeedManager::SetRun(run);
    Config::SetDefault("ns3::WifiMac::FrameRetryLimit", UintegerValue(7));
    Config::SetDefault("ns3::WifiMacQueue::MaxSize", QueueSizeValue(QueueSize("10p")));
    Config::SetDefault("ns3::WifiMacQueue::MaxDelay", TimeValue(Seconds(10)));
    Config::SetDefault("ns3::WifiRemoteStationManager::RtsCtsThreshold", UintegerValue(rts ? 100 : 65535));
    NodeContainer nodes; nodes.Create(16);
    MobilityHelper mobility;
    mobility.SetMobilityModel("ns3::ConstantPositionMobilityModel"); mobility.Install(nodes);
    auto loss = CreateObject<MatrixPropagationLossModel>(); loss->SetDefaultLoss(130);
    for (uint32_t i = 1; i < 16; ++i)
        loss->SetLoss(nodes.Get(0)->GetObject<MobilityModel>(), nodes.Get(i)->GetObject<MobilityModel>(), 60);
    auto channel = CreateObject<YansWifiChannel>(); channel->SetPropagationLossModel(loss);
    channel->SetPropagationDelayModel(CreateObject<ConstantSpeedPropagationDelayModel>());
    YansWifiPhyHelper phy; phy.SetChannel(channel);
    phy.Set("TxPowerStart", DoubleValue(20)); phy.Set("TxPowerEnd", DoubleValue(20));
    phy.Set("RxNoiseFigure", DoubleValue(7));
    phy.SetErrorRateModel("ns3::NistErrorRateModel");
    WifiHelper wifi; wifi.SetStandard(WIFI_STANDARD_80211a);
    wifi.SetRemoteStationManager("ns3::ConstantRateWifiManager", "DataMode", StringValue("OfdmRate54Mbps"),
                                "ControlMode", StringValue("OfdmRate6Mbps"));
    WifiMacHelper mac; mac.SetType("ns3::AdhocWifiMac", "QosSupported", BooleanValue(false));
    auto devices = wifi.Install(phy, mac, nodes);
    wifi.AssignStreams(devices, 0);
    // Populate supported peer modes explicitly, leaving one basic mode. Setting
    // ConstantRate::ControlMode alone controls RTS, not the ACK response rate.
    for (uint32_t i = 0; i < 16; ++i) {
        auto dev = DynamicCast<WifiNetDevice>(devices.Get(i));
        auto manager = dev->GetRemoteStationManager(); manager->Reset();
        manager->AddBasicMode(WifiMode("OfdmRate6Mbps"));
        for (uint32_t j = 0; j < 16; ++j) if (i != j) {
            auto address = Mac48Address::ConvertFrom(devices.Get(j)->GetAddress());
            for (auto mode : dev->GetPhy()->GetModeList()) manager->AddSupportedMode(address, mode);
            manager->RecordDisassociated(address);
        }
        dev->GetMac()->GetTxop()->SetMinCw(15); dev->GetMac()->GetTxop()->SetMaxCw(1023);
        addresses.push_back(Mac48Address::ConvertFrom(devices.Get(i)->GetAddress()));
        dev->GetPhy()->TraceConnectWithoutContext("PhyTxPsduBegin", MakeBoundCallback(&Tx, i));
        if (auditPhy && i == 0)
            dev->GetPhy()->GetState()->TraceConnectWithoutContext("RxOk", MakeCallback(&RxOk));
        if (auditPhy) dev->GetMac()->GetTxop()->TraceConnectWithoutContext("CwTrace", MakeBoundCallback(&Cw, i));
    }
    PacketSocketHelper helper; helper.Install(nodes);
    auto sink = Socket::CreateSocket(nodes.Get(0), TypeId::LookupByName("ns3::PacketSocketFactory"));
    PacketSocketAddress local; local.SetSingleDevice(devices.Get(0)->GetIfIndex()); local.SetProtocol(0x88b5);
    sink->Bind(local); sink->SetRecvCallback(MakeCallback(&Receive));
    warm = MicroSeconds(warmUs) + MicroSeconds(10); endMeasure = warm + MicroSeconds(measureUs);
    for (uint32_t i = 1; i <= senders; ++i) {
        auto socket = Socket::CreateSocket(nodes.Get(i), TypeId::LookupByName("ns3::PacketSocketFactory"));
        PacketSocketAddress peer; peer.SetSingleDevice(devices.Get(i)->GetIfIndex());
        peer.SetPhysicalAddress(devices.Get(0)->GetAddress()); peer.SetProtocol(0x88b5);
        NS_ABORT_MSG_IF(socket->Bind() < 0 || socket->Connect(peer) < 0, "PacketSocket setup failed");
        sockets.push_back(socket);
        Simulator::Schedule(MicroSeconds(10 + i), &Send, i - 1);
    }
    Simulator::Stop(endMeasure + MilliSeconds(100)); Simulator::Run();
    for (auto rate : dataRates) std::cout << "NS3_DATA_RATE " << rate << "\n";
    for (auto rate : controlRates) std::cout << "NS3_CONTROL_RATE " << rate << "\n";
    NS_ABORT_MSG_IF(dataRates != std::set<uint64_t>{54000000}, "DATA rate mismatch");
    NS_ABORT_MSG_IF(controlRates != std::set<uint64_t>{6000000}, "ACK/CTS/RTS rate mismatch");
    std::cout << "NS3_RESULT total_nodes=16 senders=" << senders << " rts=" << rts << " run=" << run
              << " unique=" << received << " measure_us=" << measureUs
              << " mbps=" << received * 8000.0 / measureUs << " control_mbps=6 data_mbps=54\n";
    if (auditPhy) {
        auto attempts = std::count_if(air.begin(), air.end(), [](const auto& e) {
            return e.node != 0 && e.data && e.start >= warm && e.start < endMeasure;
        });
        std::cout << "NS3_PHY_AUDIT good=" << auditGood << " overlap=" << auditOverlap
                  << " payload_overlap=" << auditPayloadOverlap << " data_attempts=" << attempts << "\n";
    }
    Simulator::Destroy();
}
