/*
Oliver Anderson
Univeristy of Bath
codma FYP 2023

Top level module file for the codma. This file connects the codma, read and write machine modules.
It is the ONLY module to drive the bus interface signals to avoid contentions.
*/


//=======================================================================================
// CODMA MODULE START
//=======================================================================================
module ip_codma_top
#()(
    // clock and reset
    input 		clk_i,
    input		reset_n_i,

    // control interface
    input		    start_i,
    input		    stop_i,
    output logic	busy_o,
    input [31:0]    task_pointer_i,
    input [31:0]    status_pointer_i,

    // bus interface
    BUS_IF.master	bus_if,

    // interrupt output
    output logic	irq_o

);
//=======================================================================================
// INTERNAL SIGNALS AND MARKERS
//=======================================================================================
import ip_codma_states_pkg::* ;

logic [31:0] reg_addr, reg_addr_wr;
logic [7:0]  reg_size, reg_size_wr;
logic need_read_i, need_read_o;
logic need_write_i, need_write_o;
logic rd_state_error, wr_state_error;
logic [7:0] write_count_s;

logic [7:0][31:0] data_reg;
logic [7:0][31:0] write_data;
logic [7:0][31:0] crc_code;
logic             crc_flag_s;

read_state_t    rd_state_r;
read_state_t    rd_state_next_s;

write_state_t   wr_state_r;
write_state_t   wr_state_next_s;

dma_state_t     dma_state_r;
dma_state_t     dma_state_next_s;

//=======================================================================================
// CONNECT THE MODULES
//=======================================================================================

ip_codma_read_machine inst_rd_machine(
    .clk_i(clk_i),
    .reset_n_i(reset_n_i),
    .rd_state_error(rd_state_error),
    .need_read_i(need_read_i),
    .need_read_o(need_read_o),
    .stop_i(stop_i),
    .data_reg_o(data_reg),
    .rd_state_r(rd_state_r),
    .rd_state_next_s(rd_state_next_s),
    .wr_state_r(wr_state_r),
    .wr_state_next_s(wr_state_next_s),
    .dma_state_r(dma_state_r),
    .dma_state_next_s(dma_state_next_s),
    .bus_if(bus_if)
);

ip_codma_write_machine inst_wr_machine(
    .clk_i(clk_i),
    .reset_n_i(reset_n_i),
    .wr_state_error(wr_state_error),
    .need_write_i(need_write_i),
    .need_write_o(need_write_o),
    .stop_i(stop_i),
    .word_count_wr(write_count_s),
    .rd_state_r(rd_state_r),
    .rd_state_next_s(rd_state_next_s),
    .wr_state_r(wr_state_r),
    .wr_state_next_s(wr_state_next_s),
    .dma_state_r(dma_state_r),
    .dma_state_next_s(dma_state_next_s),
    .bus_if(bus_if)
);

ip_codma_main_machine inst_dma_machine(
    .clk_i(clk_i),
    .reset_n_i(reset_n_i),
    .start_i(start_i),
    .stop_i(stop_i),
    .busy_o(busy_o),
    .irq_o(irq_o),
    .rd_state_error(rd_state_error),
    .wr_state_error(wr_state_error),    
    .task_pointer_i(task_pointer_i),
    .status_pointer_i(status_pointer_i),
    .reg_addr(reg_addr),
    .reg_size(reg_size),
    .reg_addr_wr(reg_addr_wr),    
    .reg_size_wr(reg_size_wr),    
    .need_read_i(need_read_i),
    .need_read_o(need_read_o),
    .need_write_i(need_write_i),
    .need_write_o(need_write_o),
    .write_data(write_data),
    .data_reg(data_reg),
    .rd_state_r(rd_state_r),
    .rd_state_next_s(rd_state_next_s),
    .wr_state_r(wr_state_r),
    .wr_state_next_s(wr_state_next_s),
    .dma_state_r(dma_state_r),
    .dma_state_next_s(dma_state_next_s),
    .crc_flag_i(crc_flag_s)
);

ip_codma_crc inst_compute_crc (
    .clk_i(clk_i),
    .reset_n_i(reset_n_i),
    .data_reg(data_reg),
    .crc_complete_flag(crc_flag_s),
    .crc_output(crc_code)
);

//=======================================================================================
//      DRIVE THE BUS. BRUM BRUM
//      .-------------------------------------------------------------.
//      '------..-------------..----------..----------..----------..--.|
//      |       \\            ||          ||          ||          ||  ||
//      |        \\           ||          ||          ||          ||  ||
//      |    ..   ||  _    _  ||    _   _ || _    _   ||    _    _||  ||
//      |    ||   || //   //  ||   //  // ||//   //   ||   //   //|| /||
//      |_.------"''----------''----------''----------''----------''--'|
//       |)|      |       |       |       |    |         |      ||==|  |
//       | |      |  _-_  |       |       |    |  .-.    |      ||==| C|
//       | |  __  |.'.-.' |   _   |   _   |    |.'.-.'.  |  __  | "__=='
//       '---------'|( )|'----------------------'|( )|'----------""
//                   '-'                          '-'
//=======================================================================================

// track the changes of states for the dma - error checking
logic [3:0] prev_dma_state;
always_ff @(posedge clk_i) begin
    if (!reset_n_i) begin
        prev_dma_state <= DMA_IDLE;
    end else begin
        prev_dma_state <= dma_state_r;
    end
end

always_comb begin
    // Standard Values
    bus_if.read         = 'd0;
    bus_if.write        = 'd0;
    bus_if.write_valid  = 'd0;
    bus_if.size         = 'd9;
    

    // Error condition - But allow for writing to the status pointer
    if (dma_state_r == DMA_ERROR && prev_dma_state != DMA_ERROR) begin
        bus_if.read         = 'd0;
        bus_if.write        = 'd0;
        bus_if.write_valid  = 'd0;
    // Wants to Read
    end else if (rd_state_r == RD_ASK) begin
        bus_if.read     = 'd1;
        bus_if.size     = reg_size;
        bus_if.addr     = reg_addr;
    end else if (rd_state_r == RD_GRANTED) begin
        bus_if.size     = reg_size;
        bus_if.addr     = reg_addr;
    // Wants to Write
    end else if (wr_state_r == WR_ASK) begin
        bus_if.write        = 'd1;
        bus_if.size         = reg_size_wr;
        bus_if.addr         = reg_addr_wr;
    end else if (wr_state_r == WR_GRANTED) begin
        bus_if.size         = reg_size_wr;
        bus_if.addr         = reg_addr_wr;
        bus_if.write_valid  = 'd1;
        bus_if.write_data   = {write_data[write_count_s+1],write_data[write_count_s]};
    end 
end


endmodule
