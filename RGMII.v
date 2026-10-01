
module ddr_out_gen #(
    parameter WIDTH = 4                 // how many bits wide the bus is
)(
    input  wire             clk,        // the clock this pin is synchronous to
    input  wire             rst_n,      // active-LOW reset (0 = reset, 1 = normal run)
    input  wire [WIDTH-1:0] d_rise,     // value to output during the "rising edge half"
    input  wire [WIDTH-1:0] d_fall,     // value to output during the "falling edge half"
    output reg  [WIDTH-1:0] q           // the actual DDR output pin(s)
);
 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            q <= {WIDTH{1'b0}};          // reset: force all output bits to 0
        else
            q <= d_rise;                 // normal run: output the "rising" value
    end
 
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n)
            q <= {WIDTH{1'b0}};
        else
            q <= d_fall;
    end
 
endmodule
 
module ddr_in_gen #(
    parameter WIDTH = 4
)(
    input  wire             clk,        // clock supplied BY THE PHY (source-synchronous)
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d,          // the incoming DDR pin(s)
    output reg  [WIDTH-1:0] q_rise,     // recovers the value the sender drove during its RISING-edge half
    output reg  [WIDTH-1:0] q_fall      // recovers the value the sender drove during its FALLING-edge half
);
 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            q_rise <= {WIDTH{1'b0}};
        else
            q_rise <= d;
    end
 
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n)
            q_fall <= {WIDTH{1'b0}};
        else
            q_fall <= d;
    end
 
endmodule

module tx_clock_mux (
    input  wire        clk125,          // 125 MHz clock input (for 1000 Mbps)
    input  wire        clk25,           // 25 MHz clock input  (for 100 Mbps)
    input  wire        clk2_5,          // 2.5 MHz clock input (for 10 Mbps)
    input  wire [1:0]  speed_sel,       // 2'b10 = 1000M, 2'b01 = 100M, 2'b00 = 10M
    output wire         tx_clk_out       // the one clock we actually transmit with
);
 

    assign tx_clk_out = (speed_sel == 2'b10) ? clk125 :
                         (speed_sel == 2'b01) ? clk25  :
                                                 clk2_5;
 
endmodule
 
 
// -----------------------------------------------------------------------
module rgmii_tx (
    input  wire        tx_clk,          // clock chosen by tx_clock_mux (125/25/2.5 MHz)
    input  wire        rst_n,
 
    // ---- MAC-facing side (byte-wide, simple, one value per clock) ----
    input  wire [7:0]  gmii_txd,        // the byte to transmit
    input  wire        gmii_tx_en,      // 1 = gmii_txd is valid data to send
    input  wire        gmii_tx_er,      // 1 = force an error onto the wire
 
    // ---- PHY-facing side (RGMII pins, DDR, nibble-wide) ----
    output wire         rgmii_txc,       // clock we send to the PHY
    output wire [3:0]   rgmii_txd,       // 4-bit DDR data to the PHY
    output wire         rgmii_tx_ctl     // 1-bit DDR control to the PHY
);
 
  
    assign rgmii_txc = tx_clk;
 
    // Build the two values that will be packed onto the single tx_ctl pin.
    wire ctl_rise = gmii_tx_en;                  // sent on the rising edge
    wire ctl_fall = gmii_tx_en ^ gmii_tx_er;      // sent on the falling edge
 
   
    ddr_out_gen #(.WIDTH(4)) u_txd_ddr (
        .clk    (tx_clk),
        .rst_n  (rst_n),
        .d_rise (gmii_txd[3:0]),         // low nibble
        .d_fall (gmii_txd[7:4]),         // high nibble
        .q      (rgmii_txd)
    );
 
    // Instantiate a 1-bit-wide DDR generator for TX_CTL.
    ddr_out_gen #(.WIDTH(1)) u_ctl_ddr (
        .clk    (tx_clk),
        .rst_n  (rst_n),
        .d_rise (ctl_rise),
        .d_fall (ctl_fall),
        .q      (rgmii_tx_ctl)
    );
 
endmodule

module rgmii_rx (
    input  wire         rgmii_rxc,       // clock supplied BY the PHY
    input  wire         rst_n,
    input  wire [3:0]   rgmii_rxd,       // 4-bit DDR data from the PHY
    input  wire         rgmii_rx_ctl,    // 1-bit DDR control from the PHY
 
    // ---- MAC-facing side (byte-wide, one value per clock) ----
    output reg  [7:0]   gmii_rxd,        // the reassembled byte
    output reg           gmii_rx_dv,      // 1 = gmii_rxd is valid received data
    output reg           gmii_rx_er       // 1 = a receive error was flagged
);
 
    wire [3:0] d_rise, d_fall;    // the two nibbles recovered from rgmii_rxd
    wire       ctl_rise, ctl_fall; // the two bits recovered from rgmii_rx_ctl
 
    // Recover the low nibble (sampled at rising edge) and the high
    // nibble (sampled at falling edge) from the 4-bit DDR input bus.
    ddr_in_gen #(.WIDTH(4)) u_rxd_ddr (
        .clk    (rgmii_rxc),
        .rst_n  (rst_n),
        .d      (rgmii_rxd),
        .q_rise (d_rise),
        .q_fall (d_fall)
    );
 
    // Recover the two control bits the same way.
    ddr_in_gen #(.WIDTH(1)) u_ctl_ddr (
        .clk    (rgmii_rxc),
        .rst_n  (rst_n),
        .d      (rgmii_rx_ctl),
        .q_rise (ctl_rise),
        .q_fall (ctl_fall)
    );
 
    always @(negedge rgmii_rxc or negedge rst_n) begin
        if (!rst_n) begin
            gmii_rxd   <= 8'b0;
            gmii_rx_dv <= 1'b0;
            gmii_rx_er <= 1'b0;
        end else begin
       
            gmii_rxd   <= {d_rise, d_fall};
 
         
            gmii_rx_dv <= ctl_fall;
 
            // Per the RGMII spec: XOR of both control bits = "error flag".
            gmii_rx_er <= ctl_rise ^ ctl_fall;
        end
    end
 
endmodule
 

module rgmii_mac_top (
    // ---- Reference clocks, normally generated by a PLL/MMCM ----
    input  wire        clk125,
    input  wire        clk25,
    input  wire        clk2_5,
    input  wire        rst_n,
 
    // ---- Current link speed, normally read from the PHY's status
    //      register over MDIO after autonegotiation finishes ----
    input  wire [1:0]  speed_sel,       // 2'b10=1000M, 2'b01=100M, 2'b00=10M
 
    // ---- MAC-facing TX interface (drive this from your MAC/FIFO logic) ----
    input  wire [7:0]  mac_txd,
    input  wire        mac_tx_en,
    input  wire        mac_tx_er,
 
    // ---- MAC-facing RX interface (your MAC/FIFO logic reads this) ----
    output wire [7:0]  mac_rxd,
    output wire         mac_rx_dv,
    output wire         mac_rx_er,
 
    // ---- Physical RGMII pins, connect these to the PHY chip ----
    output wire         rgmii_txc,
    output wire [3:0]   rgmii_txd,
    output wire         rgmii_tx_ctl,
    input  wire         rgmii_rxc,
    input  wire [3:0]   rgmii_rxd,
    input  wire         rgmii_rx_ctl
);
 
    // The wire carrying whichever clock frequency matches the current
    // link speed, on its way to becoming rgmii_txc.
    wire tx_clk_sel;
 
    // Pick the correct transmit clock for the current speed.
    tx_clock_mux u_clkmux (
        .clk125     (clk125),
        .clk25      (clk25),
        .clk2_5     (clk2_5),
        .speed_sel  (speed_sel),
        .tx_clk_out (tx_clk_sel)
    );
 
    // Build and drive the transmit path.
    rgmii_tx u_tx (
        .tx_clk       (tx_clk_sel),
        .rst_n        (rst_n),
        .gmii_txd     (mac_txd),
        .gmii_tx_en   (mac_tx_en),
        .gmii_tx_er   (mac_tx_er),
        .rgmii_txc    (rgmii_txc),
        .rgmii_txd    (rgmii_txd),
        .rgmii_tx_ctl (rgmii_tx_ctl)
    );
 
    // Build and drive the receive path (clocked by the PHY's own clock).
    rgmii_rx u_rx (
        .rgmii_rxc    (rgmii_rxc),
        .rst_n        (rst_n),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl),
        .gmii_rxd     (mac_rxd),
        .gmii_rx_dv   (mac_rx_dv),
        .gmii_rx_er   (mac_rx_er)
    );
 
endmodule
 


