*&---------------------------------------------------------------------*
*& Report Z_VERIF_NOTAS
*&---------------------------------------------------------------------*
*& Título     : Verificação de Notas SAP e da sua cadeia de pré-requisitos
*& Transação  : ZT_VERIF_NOTAS
*& Autor      : João Victor Ferrareis Ribeiro
*& Data       : 21.09.2026
*&---------------------------------------------------------------------*
*& Objetivo:
*&   A partir das Notas SAP informadas na tela de seleção (valores
*&   individuais, intervalos ou padrões), identificar todas as notas
*&   pré-requisito (diretas e indiretas) de cada uma e exibir, em ALV,
*&   os dados e status no sistema (status de implementação, status de
*&   processamento e existência de atividades manuais, conforme SNOTE).
*&
*& Arquitetura (padrão Factory + injeção de dependências):
*&   - LCL_FABRICA_VERIFICADOR : único ponto de criação do verificador.
*&     Monta o objeto com as dependências produtivas ou, quando
*&     informadas, com as dependências recebidas (dublês de teste).
*&   - LCL_VERIFICADOR_NOTAS   : regras de negócio (seleção, ordenação,
*&     filtros e limpeza). CREATE PRIVATE: só a fábrica o instancia.
*&   - LIF_REPOSITORIO_NOTAS   : acesso aos dados das notas.
*&       LCL_REPOSITORIO_NOTAS_SAP -> tabela CWBNTHEAD e FMs SCWB_*.
*&   - LIF_EXIBIDOR_NOTAS      : apresentação do resultado.
*&       LCL_EXIBIDOR_ALV          -> CL_SALV_TABLE e mensagens.
*&   Como as regras não acessam banco nem tela diretamente, são
*&   cobertas por testes unitários (classe LTC_VERIFICADOR_NOTAS).
*&
*& Lógica principal:
*&   1. Seleção das notas a processar:
*&      - notas carregadas no sistema (tabela CWBNTHEAD) que atendem ao
*&        critério S_NOTA;
*&      - valores individuais (I/EQ) de S_NOTA ainda não carregados, que
*&        são exibidos com a indicação "Nota não carregada no sistema".
*&   2. Para cada nota selecionada, em ordem crescente:
*&      a. Leitura da nota (FM SCWB_NOTE_READ) e das suas atividades
*&         manuais (FM SCWB_API_CINST_QUEUE_GET).
*&      b. Somente a própria nota é exibida (passos c a f ignorados)
*&         quando:
*&         - ela não está carregada no sistema (sem instruções de
*&           correção não há como determinar os pré-requisitos); ou
*&         - o filtro P_OCIMP está marcado e a nota tem status de
*&           implementação 'A' ou status de processamento 'E'.
*&      c. Busca da árvore de pré-requisitos
*&         (FM SCWB_CINST_PRECONDITION_DATA).
*&      d. Ordenação pela ordem de implementação: notas mais profundas
*&         na árvore (sem dependências) primeiro; em caso de empate,
*&         pelo número da nota. A própria nota e as repetições da árvore
*&         são descartadas antes da leitura dos atributos.
*&      e. Leitura dos atributos de cada pré-requisito.
*&      f. Se o filtro P_OCIMP estiver marcado, remoção dos
*&         pré-requisitos com status de implementação 'A' ou status de
*&         processamento 'E'.
*&      g. A nota selecionada é incluída como última linha do seu
*&         bloco, destacada em cor (constante GC_COR_NOTA_PRINCIPAL).
*&   3. Limpeza final da tabela de saída: notas (NUMM) repetidas são
*&      removidas, mantendo apenas a primeira ocorrência. Se a repetição
*&      removida for uma nota selecionada, o destaque em cor é
*&      transferido para a ocorrência mantida.
*&   4. Exibição em ALV (CL_SALV_TABLE). A coluna NOTA_PRINC indica a
*&      nota selecionada a cujo bloco a linha pertence. As colunas
*&      ATIV_MANUAL_PRE e ATIV_MANUAL_POS indicam, como caixa de
*&      seleção, se a nota possui atividades manuais antes/depois da
*&      implementação.
*&
*& Observações:
*&   - Notas pré-requisito ainda não carregadas no sistema (SNOTE) são
*&     listadas apenas com o número e uma indicação no status; como não
*&     possuem status, nunca são removidas pelo filtro.
*&   - Se a árvore de pré-requisitos de uma nota não puder ser
*&     determinada (ex.: nota sem instruções de correção), apenas a
*&     própria nota é exibida no seu bloco.
*&   - Falhas na determinação das atividades manuais não impedem a
*&     exibição da nota: as colunas correspondentes ficam desmarcadas.
*&   - Os códigos internos dos status são mantidos nas colunas técnicas
*&     NTSTATUS_COD e PRSTATUS_COD (ocultas no ALV), pois as colunas
*&     NTSTATUS e PRSTATUS contêm os textos já convertidos.
*&   - Intervalos amplos em S_NOTA podem gerar tempo de execução alto,
*&     pois a árvore de pré-requisitos e as atividades manuais são
*&     determinadas nota a nota.
*&   - Requer release ABAP 7.50 ou superior (Open SQL com INTO no final
*&     do comando e IS INSTANCE OF nos testes).
*&   - Testes unitários: Ctrl+Shift+F10 (Programa > Executar > Testes
*&     unitários) no SE38/SE80 ou no ADT.
*&---------------------------------------------------------------------*
REPORT z_verif_notas.

*----------------------------------------------------------------------*
* Objetos globais
*----------------------------------------------------------------------*
" Referência de tipo para o SELECT-OPTIONS (uso exclusivo da tela)
DATA gv_sel_nota TYPE cwbntnumm.

*----------------------------------------------------------------------*
* Tela de seleção
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE TEXT-b01.
  SELECT-OPTIONS s_nota FOR gv_sel_nota.
SELECTION-SCREEN END OF BLOCK b01.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE TEXT-b02.
  PARAMETERS p_ocimp AS CHECKBOX DEFAULT abap_false.
SELECTION-SCREEN END OF BLOCK b02.

*----------------------------------------------------------------------*
* Exceção LCX_NOTA_NAO_ENCONTRADA
*----------------------------------------------------------------------*
"! Nota não carregada no sistema (SNOTE).
CLASS lcx_nota_nao_encontrada DEFINITION INHERITING FROM cx_static_check FINAL.
ENDCLASS.

CLASS lcx_nota_nao_encontrada IMPLEMENTATION.
ENDCLASS.

*----------------------------------------------------------------------*
* Interface LIF_REPOSITORIO_NOTAS
*----------------------------------------------------------------------*
"! Acesso aos dados das Notas SAP no sistema.
INTERFACE lif_repositorio_notas.

  TYPES:
    "! Critério de seleção de notas (compatível com S_NOTA)
    ty_r_nota  TYPE RANGE OF cwbntnumm,
    "! Lista de notas (ordenada, sem repetições)
    ty_t_notas TYPE SORTED TABLE OF cwbntnumm WITH UNIQUE KEY table_line,
    "! Dados de uma nota lida no sistema
    BEGIN OF ty_s_nota,
      numm            TYPE bcwbn_note-key-numm,
      versno          TYPE bcwbn_note-key-versno,
      themk           TYPE bcwbn_note-attributes-themk,
      langu           TYPE bcwbn_note-langu,
      stext           TYPE bcwbn_note-stext,
      ntstatus_cod    TYPE bcwbn_note-customer_attributes-ntstatus,
      prstatus_cod    TYPE bcwbn_note-customer_attributes-prstatus,
      ntstatus_txt    TYPE char40,
      prstatus_txt    TYPE char40,
      ativ_manual_pre TYPE abap_bool,   " Possui atividade manual antes da implementação
      ativ_manual_pos TYPE abap_bool,   " Possui atividade manual após a implementação
    END OF ty_s_nota.

  "! Notas carregadas no sistema que atendem ao critério.
  "! @parameter it_notas | Critério de seleção
  "! @parameter rt_notas | Notas carregadas
  METHODS selecionar_carregadas
    IMPORTING
      it_notas        TYPE ty_r_nota
    RETURNING
      VALUE(rt_notas) TYPE ty_t_notas.

  "! Lê atributos, status (código e texto) e atividades manuais de uma
  "! nota.
  "! @parameter iv_nota                  | Número da nota
  "! @parameter rs_nota                  | Dados da nota
  "! @raising   lcx_nota_nao_encontrada  | Nota não carregada
  METHODS ler_nota
    IMPORTING
      iv_nota        TYPE cwbntnumm
    RETURNING
      VALUE(rs_nota) TYPE ty_s_nota
    RAISING
      lcx_nota_nao_encontrada.

  "! Árvore de pré-requisitos de uma nota.
  "! @parameter iv_nota   | Número da nota
  "! @parameter rt_prereq | Árvore (vazia se não puder ser determinada)
  METHODS buscar_prerequisitos
    IMPORTING
      iv_nota          TYPE cwbntnumm
    RETURNING
      VALUE(rt_prereq) TYPE tt_cwb_note_display.

ENDINTERFACE.

*----------------------------------------------------------------------*
* Interface LIF_VERIFICADOR_NOTAS
*----------------------------------------------------------------------*
"! Verificação de Notas SAP e das suas cadeias de pré-requisitos.
INTERFACE lif_verificador_notas.

  TYPES:
    "! Linha de saída
    BEGIN OF ty_s_saida,
      nota_princ      TYPE cwbntnumm,                               " Nota selecionada (bloco)
      numm            TYPE bcwbn_note-key-numm,
      versno          TYPE bcwbn_note-key-versno,
      themk           TYPE bcwbn_note-attributes-themk,
      langu           TYPE bcwbn_note-langu,
      stext           TYPE bcwbn_note-stext,
      ntstatus        TYPE char40,
      prstatus        TYPE char40,
      ativ_manual_pre TYPE abap_bool,                               " Atividade manual pré-implementação
      ativ_manual_pos TYPE abap_bool,                               " Atividade manual pós-implementação
      ntstatus_cod    TYPE bcwbn_note-customer_attributes-ntstatus, " Código interno (técnica)
      prstatus_cod    TYPE bcwbn_note-customer_attributes-prstatus, " Código interno (técnica)
      t_color         TYPE lvc_t_scol,                              " Cores da linha (oculta)
    END OF ty_s_saida,
    "! Tabela de saída
    ty_t_saida TYPE STANDARD TABLE OF ty_s_saida WITH EMPTY KEY.

  "! Seleção, leitura, filtros e limpeza, sem exibição.
  "! @parameter rt_saida | Linhas resultantes
  METHODS processar
    RETURNING
      VALUE(rt_saida) TYPE ty_t_saida.

  "! Processa e apresenta o resultado.
  METHODS executar.

ENDINTERFACE.

*----------------------------------------------------------------------*
* Interface LIF_EXIBIDOR_NOTAS
*----------------------------------------------------------------------*
"! Apresentação do resultado da verificação.
INTERFACE lif_exibidor_notas.

  "! Exibe as linhas de saída.
  "! @parameter it_saida | Linhas a exibir
  METHODS exibir
    IMPORTING
      it_saida TYPE lif_verificador_notas=>ty_t_saida.

  "! Informa que nenhuma nota foi encontrada para a seleção.
  METHODS informar_sem_dados.

ENDINTERFACE.

*----------------------------------------------------------------------*
* Classe LCL_REPOSITORIO_NOTAS_SAP - Definição
*----------------------------------------------------------------------*
"! Repositório produtivo: CWBNTHEAD e módulos de função da SNOTE.
CLASS lcl_repositorio_notas_sap DEFINITION FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES lif_repositorio_notas.

  PRIVATE SECTION.

    CONSTANTS:
      "! Tipo de atividade manual executada antes da implementação
      gc_ativ_manual_antes TYPE scwb_api_correction_instr-type VALUE 'B'.

    "! Determina se a nota possui atividades manuais antes/depois da
    "! implementação. Erros na determinação não interrompem a leitura
    "! da nota: os indicadores apenas permanecem desmarcados.
    "! @parameter is_nota | Nota já lida (chave e versão preenchidas)
    "! @parameter cs_nota | Dados da nota (indicadores preenchidos)
    METHODS determinar_ativ_manuais
      IMPORTING
        is_nota TYPE bcwbn_note
      CHANGING
        cs_nota TYPE lif_repositorio_notas=>ty_s_nota.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_REPOSITORIO_NOTAS_SAP - Implementação
*----------------------------------------------------------------------*
CLASS lcl_repositorio_notas_sap IMPLEMENTATION.

  METHOD lif_repositorio_notas~selecionar_carregadas.

    SELECT DISTINCT numm
      FROM cwbnthead
      WHERE numm IN @it_notas
      INTO TABLE @rt_notas.

  ENDMETHOD.


  METHOD lif_repositorio_notas~ler_nota.

    DATA ls_nota TYPE bcwbn_note.

    ls_nota-key-numm = iv_nota.

    " As instruções de correção não são lidas aqui: uma nota sem
    " instruções não deve ser tratada como "não carregada"
    CALL FUNCTION 'SCWB_NOTE_READ'
      EXPORTING
        iv_read_attributes          = abap_true
        iv_read_short_text          = abap_true
        iv_read_customer_attributes = abap_true
      CHANGING
        cs_note                     = ls_nota
      EXCEPTIONS
        note_not_found              = 1
        language_not_found          = 2
        unreadable_text_format      = 3
        corr_instruction_not_found  = 4
        OTHERS                      = 5.

    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_nota_nao_encontrada.
    ENDIF.

    rs_nota = VALUE #( numm         = ls_nota-key-numm
                       versno       = ls_nota-key-versno
                       themk        = ls_nota-attributes-themk
                       langu        = ls_nota-langu
                       stext        = ls_nota-stext
                       ntstatus_cod = ls_nota-customer_attributes-ntstatus
                       prstatus_cod = ls_nota-customer_attributes-prstatus ).

    CALL FUNCTION 'CONVERSION_EXIT_CWBNT_OUTPUT'
      EXPORTING
        input  = rs_nota-ntstatus_cod
      IMPORTING
        output = rs_nota-ntstatus_txt.

    CALL FUNCTION 'CONVERSION_EXIT_PSTAT_OUTPUT'
      EXPORTING
        input  = rs_nota-prstatus_cod
      IMPORTING
        output = rs_nota-prstatus_txt.

    determinar_ativ_manuais(
      EXPORTING
        is_nota = ls_nota
      CHANGING
        cs_nota = rs_nota ).

  ENDMETHOD.


  METHOD determinar_ativ_manuais.

    DATA ls_nota              TYPE bcwbn_note.
    DATA lt_notas             TYPE scwb_api_notenumbers.
    DATA lt_component_vector  TYPE STANDARD TABLE OF scwb_api_comp_vector.
    DATA lt_manual_activities TYPE scwb_api_t_correction_instr.

    " Instruções de correção da nota (chave e versão já determinadas)
    ls_nota = is_nota.

    CALL FUNCTION 'SCWB_NOTE_READ'
      EXPORTING
        iv_read_corr_instructions = abap_true
      CHANGING
        cs_note                   = ls_nota
      EXCEPTIONS
        OTHERS                    = 1.

    " Sem instruções de correção não há fila de implementação a avaliar
    IF sy-subrc <> 0 OR ls_nota-corr_instructions IS INITIAL.
      RETURN.
    ENDIF.

    APPEND is_nota-key-numm TO lt_notas.

    CALL FUNCTION 'SCWB_API_CINST_QUEUE_GET'
      IMPORTING
        et_manual_activities       = lt_manual_activities
      TABLES
        it_notes                   = lt_notas
        it_component_vector_target = lt_component_vector
      EXCEPTIONS
        OTHERS                     = 1.

    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    LOOP AT lt_manual_activities ASSIGNING FIELD-SYMBOL(<ls_ativ_manual>)
         WHERE manual_activity IS NOT INITIAL.

      " A fila pode conter instruções de pré-requisitos: considera
      " somente as instruções de correção da própria nota
      READ TABLE ls_nota-corr_instructions TRANSPORTING NO FIELDS
           WITH KEY key-insta  = <ls_ativ_manual>-insta
                    key-pakid  = <ls_ativ_manual>-pakid
                    key-aleid  = <ls_ativ_manual>-aleid
                    key-versno = <ls_ativ_manual>-versno.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.

      IF <ls_ativ_manual>-type = gc_ativ_manual_antes.
        cs_nota-ativ_manual_pre = abap_true.
      ELSE.
        cs_nota-ativ_manual_pos = abap_true.
      ENDIF.

      " Ambos os indicadores já determinados: nada mais a avaliar
      IF cs_nota-ativ_manual_pre = abap_true AND cs_nota-ativ_manual_pos = abap_true.
        EXIT.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD lif_repositorio_notas~buscar_prerequisitos.

    CALL FUNCTION 'SCWB_CINST_PRECONDITION_DATA'
      EXPORTING
        iv_notenum                 = iv_nota
      IMPORTING
        et_notedisplay             = rt_prereq
      EXCEPTIONS
        note_not_found             = 1
        no_valid_corr_instructions = 2
        note_download_cancelled    = 3
        inconsistent_delivery_data = 4
        level_not_found            = 5
        undefined                  = 6
        language_not_found         = 7
        unreadable_text_format     = 8
        corr_instruction_not_found = 9
        OTHERS                     = 10.

    IF sy-subrc <> 0.
      " Sem árvore de pré-requisitos: apenas a própria nota será exibida
      CLEAR rt_prereq.
    ENDIF.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_EXIBIDOR_ALV - Definição
*----------------------------------------------------------------------*
"! Exibidor produtivo: ALV (CL_SALV_TABLE) e mensagens de status.
CLASS lcl_exibidor_alv DEFINITION FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES lif_exibidor_notas.

  PRIVATE SECTION.

    CONSTANTS:
      "! Nome técnico da coluna de cores na estrutura de saída
      gc_coluna_cor           TYPE lvc_fname VALUE 'T_COLOR',
      "! Nome técnico da coluna com o código do status de implementação
      gc_coluna_nt_status_cod TYPE lvc_fname VALUE 'NTSTATUS_COD',
      "! Nome técnico da coluna com o código do status de processamento
      gc_coluna_pr_status_cod TYPE lvc_fname VALUE 'PRSTATUS_COD',
      "! Nome técnico da coluna com a nota selecionada (bloco)
      gc_coluna_nota_princ    TYPE lvc_fname VALUE 'NOTA_PRINC',
      "! Nome técnico da coluna de atividade manual pré-implementação
      gc_coluna_ativ_pre      TYPE lvc_fname VALUE 'ATIV_MANUAL_PRE',
      "! Nome técnico da coluna de atividade manual pós-implementação
      gc_coluna_ativ_pos      TYPE lvc_fname VALUE 'ATIV_MANUAL_POS'.

    "! Cópia dos dados exibidos (CL_SALV_TABLE exige referência viva)
    DATA mt_saida TYPE lif_verificador_notas=>ty_t_saida.

    "! Define a coluna de cores, as colunas técnicas/ocultas e os
    "! textos de cabeçalho de todas as colunas do ALV.
    "! @parameter io_colunas | Colunas do ALV
    METHODS configurar_colunas
      IMPORTING
        io_colunas TYPE REF TO cl_salv_columns_table.

    "! Define os textos de cabeçalho de uma coluna do ALV.
    "! @parameter io_colunas | Colunas do ALV
    "! @parameter iv_coluna  | Nome técnico da coluna
    "! @parameter iv_curto   | Texto curto (até 10 caracteres)
    "! @parameter iv_medio   | Texto médio (até 20 caracteres)
    "! @parameter iv_longo   | Texto longo (até 40 caracteres)
    METHODS configurar_coluna
      IMPORTING
        io_colunas TYPE REF TO cl_salv_columns_table
        iv_coluna  TYPE lvc_fname
        iv_curto   TYPE csequence
        iv_medio   TYPE csequence
        iv_longo   TYPE csequence.

    "! Exibe uma coluna como caixa de seleção (somente leitura).
    "! @parameter io_colunas | Colunas do ALV
    "! @parameter iv_coluna  | Nome técnico da coluna
    METHODS configurar_caixa_selecao
      IMPORTING
        io_colunas TYPE REF TO cl_salv_columns_table
        iv_coluna  TYPE lvc_fname.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_EXIBIDOR_ALV - Implementação
*----------------------------------------------------------------------*
CLASS lcl_exibidor_alv IMPLEMENTATION.

  METHOD lif_exibidor_notas~exibir.

    DATA lo_alv TYPE REF TO cl_salv_table.

    mt_saida = it_saida.

    TRY.
        cl_salv_table=>factory(
          IMPORTING
            r_salv_table = lo_alv
          CHANGING
            t_table      = mt_saida ).
      CATCH cx_salv_msg INTO DATA(lx_msg).
        MESSAGE lx_msg TYPE 'S' DISPLAY LIKE 'E'.
        RETURN.
    ENDTRY.

    lo_alv->get_functions( )->set_all( abap_true ).

    DATA(lo_display) = lo_alv->get_display_settings( ).
    lo_display->set_striped_pattern( abap_true ).
    lo_display->set_list_header( 'Notas SAP e pré-requisitos'(h01) ).

    configurar_colunas( lo_alv->get_columns( ) ).

    lo_alv->display( ).

  ENDMETHOD.


  METHOD lif_exibidor_notas~informar_sem_dados.
    MESSAGE 'Nenhuma nota encontrada para a seleção.'(m01) TYPE 'S' DISPLAY LIKE 'W'.
  ENDMETHOD.


  METHOD configurar_colunas.

    io_colunas->set_optimize( abap_true ).

    " Coluna com as cores das linhas (fica oculta automaticamente)
    TRY.
        io_colunas->set_color_column( gc_coluna_cor ).
      CATCH cx_salv_data_error.
        " Sem destaque em cor; a lista é exibida normalmente
    ENDTRY.

    " Códigos internos dos status: uso apenas no filtro, não são exibidos
    TRY.
        io_colunas->get_column( gc_coluna_nt_status_cod )->set_technical( abap_true ).
        io_colunas->get_column( gc_coluna_pr_status_cod )->set_technical( abap_true ).
      CATCH cx_salv_not_found.
        " Coluna inexistente na estrutura de saída: nada a ocultar
    ENDTRY.

    configurar_coluna( io_colunas = io_colunas iv_coluna = gc_coluna_nota_princ
                       iv_curto   = 'Nt.Princ.'(c14)
                       iv_medio   = 'Nota principal'(c15)
                       iv_longo   = 'Nota principal'(c15) ).

    " Nota principal: disponível via layout, oculta por padrão
    TRY.
        io_colunas->get_column( gc_coluna_nota_princ )->set_visible( abap_false ).
      CATCH cx_salv_not_found.
        " Coluna inexistente na estrutura de saída: nada a ocultar
    ENDTRY.

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'NUMM'
                       iv_curto   = 'Nota'(c01)
                       iv_medio   = 'Nota SAP'(c02)
                       iv_longo   = 'Nota SAP'(c02) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'VERSNO'
                       iv_curto   = 'Versão'(c03)
                       iv_medio   = 'Versão'(c03)
                       iv_longo   = 'Versão'(c03) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'THEMK'
                       iv_curto   = 'Componen.'(c04)
                       iv_medio   = 'Componente'(c05)
                       iv_longo   = 'Componente'(c05) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'LANGU'
                       iv_curto   = 'Idioma'(c06)
                       iv_medio   = 'Idioma'(c06)
                       iv_longo   = 'Idioma'(c06) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'STEXT'
                       iv_curto   = 'Descrição'(c07)
                       iv_medio   = 'Descrição'(c07)
                       iv_longo   = 'Descrição'(c07) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'NTSTATUS'
                       iv_curto   = 'St. Impl.'(c08)
                       iv_medio   = 'Status implementação'(c09)
                       iv_longo   = 'Status de implementação'(c10) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = 'PRSTATUS'
                       iv_curto   = 'St. Proc.'(c11)
                       iv_medio   = 'Status processamento'(c12)
                       iv_longo   = 'Status de processamento'(c13) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = gc_coluna_ativ_pre
                       iv_curto   = 'Ativ.Pré'(c16)
                       iv_medio   = 'Ativ. manual pré'(c17)
                       iv_longo   = 'Atividade manual pré-implementação'(c18) ).

    configurar_coluna( io_colunas = io_colunas iv_coluna = gc_coluna_ativ_pos
                       iv_curto   = 'Ativ.Pós'(c19)
                       iv_medio   = 'Ativ. manual pós'(c20)
                       iv_longo   = 'Atividade manual pós-implementação'(c21) ).

    configurar_caixa_selecao( io_colunas = io_colunas iv_coluna = gc_coluna_ativ_pre ).
    configurar_caixa_selecao( io_colunas = io_colunas iv_coluna = gc_coluna_ativ_pos ).

  ENDMETHOD.


  METHOD configurar_coluna.

    TRY.
        DATA(lo_coluna) = io_colunas->get_column( iv_coluna ).
        lo_coluna->set_short_text( CONV scrtext_s( iv_curto ) ).
        lo_coluna->set_medium_text( CONV scrtext_m( iv_medio ) ).
        lo_coluna->set_long_text( CONV scrtext_l( iv_longo ) ).
      CATCH cx_salv_not_found.
        " Coluna inexistente na estrutura de saída: mantém textos padrão
    ENDTRY.

  ENDMETHOD.


  METHOD configurar_caixa_selecao.

    TRY.
        CAST cl_salv_column_table( io_colunas->get_column( iv_coluna )
          )->set_cell_type( if_salv_c_cell_type=>checkbox ).
      CATCH cx_salv_not_found.
        " Coluna inexistente na estrutura de saída: mantém exibição padrão
    ENDTRY.

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_VERIFICADOR_NOTAS - Definição
*----------------------------------------------------------------------*
CLASS lcl_fabrica_verificador DEFINITION DEFERRED.

"! Regras de negócio da verificação de notas. Instanciada somente pela
"! fábrica LCL_FABRICA_VERIFICADOR.
CLASS lcl_verificador_notas DEFINITION FINAL
  CREATE PRIVATE
  FRIENDS lcl_fabrica_verificador.

  PUBLIC SECTION.

    INTERFACES lif_verificador_notas.

    "! @parameter it_notas          | Critério de seleção das notas
    "! @parameter iv_ocultar_status | X = ocultar notas com status de
    "!                                implementação/processamento
    "!                                concluído (ver constantes)
    "! @parameter io_repositorio    | Acesso aos dados das notas
    "! @parameter io_exibidor       | Apresentação do resultado
    METHODS constructor
      IMPORTING
        it_notas          TYPE lif_repositorio_notas=>ty_r_nota
        iv_ocultar_status TYPE abap_bool
        io_repositorio    TYPE REF TO lif_repositorio_notas
        io_exibidor       TYPE REF TO lif_exibidor_notas.

  PRIVATE SECTION.

    TYPES:
      "! Registro auxiliar para ordenação por profundidade na árvore
      BEGIN OF ty_s_ordenacao,
        profundidade TYPE i,
        nota         TYPE cwb_note_display,
      END OF ty_s_ordenacao,
      ty_t_ordenacao TYPE STANDARD TABLE OF ty_s_ordenacao WITH EMPTY KEY,
      "! Árvore de pré-requisitos indexada pelo ID do nó (acesso binário)
      ty_t_por_aleid TYPE SORTED TABLE OF cwb_note_display
                     WITH NON-UNIQUE KEY aleid.

    CONSTANTS:
      "! Status de implementação das notas ocultadas pelo filtro P_OCIMP
      gc_status_impl_ocultar TYPE bcwbn_note-customer_attributes-ntstatus VALUE 'A',
      "! Status de processamento das notas ocultadas pelo filtro P_OCIMP
      gc_status_proc_ocultar TYPE bcwbn_note-customer_attributes-prstatus VALUE 'E',
      "! Cor da linha das notas selecionadas (tipo COL: verde)
      gc_cor_nota_principal  TYPE lvc_col VALUE col_positive,
      "! Intensidade da cor (1 = intensificada, visível sobre o zebrado)
      gc_cor_intensificada   TYPE lvc_int VALUE 1.

    "! Critério de seleção das notas (S_NOTA)
    DATA mt_notas          TYPE lif_repositorio_notas=>ty_r_nota.
    "! Indicador do filtro de status (P_OCIMP)
    DATA mv_ocultar_status TYPE abap_bool.
    "! Acesso aos dados das notas
    DATA mo_repositorio    TYPE REF TO lif_repositorio_notas.
    "! Apresentação do resultado
    DATA mo_exibidor       TYPE REF TO lif_exibidor_notas.

    "! Determina as notas a processar a partir do critério de seleção.
    "! @parameter rt_notas | Notas a processar, em ordem crescente
    METHODS selecionar_notas
      RETURNING
        VALUE(rt_notas) TYPE lif_repositorio_notas=>ty_t_notas.

    "! Monta o bloco de saída de uma nota selecionada: pré-requisitos
    "! (já filtrados) seguidos da própria nota, destacada em cor.
    "! @parameter iv_nota  | Nota selecionada
    "! @parameter rt_saida | Linhas do bloco
    METHODS processar_nota
      IMPORTING
        iv_nota         TYPE cwbntnumm
      RETURNING
        VALUE(rt_saida) TYPE lif_verificador_notas=>ty_t_saida.

    "! Lê a nota selecionada e aplica a cor de destaque na linha.
    "! @parameter iv_nota  | Nota selecionada
    "! @parameter rs_saida | Linha de saída da nota
    METHODS ler_nota_principal
      IMPORTING
        iv_nota         TYPE cwbntnumm
      RETURNING
        VALUE(rs_saida) TYPE lif_verificador_notas=>ty_s_saida.

    "! Indica se a linha deve ser ocultada pelo filtro de status.
    "! @parameter is_saida   | Linha de saída
    "! @parameter rv_ocultar | abap_true = linha deve ser ocultada
    METHODS deve_ocultar
      IMPORTING
        is_saida          TYPE lif_verificador_notas=>ty_s_saida
      RETURNING
        VALUE(rv_ocultar) TYPE abap_bool.

    "! Indica se a nota da linha está carregada no sistema (SNOTE).
    "! Notas carregadas sempre possuem versão.
    "! @parameter is_saida     | Linha de saída
    "! @parameter rv_carregada | abap_true = nota carregada
    METHODS esta_carregada
      IMPORTING
        is_saida            TYPE lif_verificador_notas=>ty_s_saida
      RETURNING
        VALUE(rv_carregada) TYPE abap_bool.

    "! Ordena a árvore pela ordem de implementação, remove a própria
    "! nota e as repetições.
    "! @parameter it_prereq | Árvore de pré-requisitos original
    "! @parameter iv_nota   | Nota selecionada (raiz da árvore)
    "! @parameter rt_prereq | Lista ordenada e sem repetições
    METHODS ordenar_prerequisitos
      IMPORTING
        it_prereq        TYPE tt_cwb_note_display
        iv_nota          TYPE cwbntnumm
      RETURNING
        VALUE(rt_prereq) TYPE tt_cwb_note_display.

    "! Calcula a profundidade de um nó na árvore (quantidade de
    "! ancestrais). Protegido contra referências cíclicas.
    "! @parameter is_nota         | Nó da árvore
    "! @parameter it_por_aleid    | Árvore indexada pelo ID do nó
    "! @parameter rv_profundidade | Profundidade (0 = raiz)
    METHODS calcular_profundidade
      IMPORTING
        is_nota                TYPE cwb_note_display
        it_por_aleid           TYPE ty_t_por_aleid
      RETURNING
        VALUE(rv_profundidade) TYPE i.

    "! Remove notas repetidas da árvore, mantendo a primeira ocorrência.
    "! Evita ler a mesma nota mais de uma vez.
    "! @parameter it_prereq | Lista com possíveis repetições
    "! @parameter rt_prereq | Lista sem repetições
    METHODS remover_duplicadas
      IMPORTING
        it_prereq        TYPE tt_cwb_note_display
      RETURNING
        VALUE(rt_prereq) TYPE tt_cwb_note_display.

    "! Limpeza final da saída: remove notas (NUMM) repetidas, mantendo
    "! a primeira ocorrência (e o destaque em cor, se a repetição
    "! removida for uma nota selecionada).
    "! @parameter it_saida | Saída com possíveis repetições
    "! @parameter rt_saida | Saída sem repetições
    METHODS remover_repetidas_saida
      IMPORTING
        it_saida        TYPE lif_verificador_notas=>ty_t_saida
      RETURNING
        VALUE(rt_saida) TYPE lif_verificador_notas=>ty_t_saida.

    "! Lê os atributos e status de uma nota no sistema.
    "! @parameter iv_nota           | Número da nota
    "! @parameter iv_nota_principal | Nota selecionada a cujo bloco a
    "!                                linha pertence
    "! @parameter rs_saida          | Linha de saída preenchida
    METHODS ler_dados_nota
      IMPORTING
        iv_nota           TYPE cwbntnumm
        iv_nota_principal TYPE cwbntnumm
      RETURNING
        VALUE(rs_saida)   TYPE lif_verificador_notas=>ty_s_saida.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_FABRICA_VERIFICADOR - Definição
*----------------------------------------------------------------------*
"! Fábrica do verificador de notas (padrão Factory). Centraliza a
"! criação e a montagem das dependências.
CLASS lcl_fabrica_verificador DEFINITION ABSTRACT FINAL.

  PUBLIC SECTION.

    "! Cria um verificador de notas.
    "! @parameter it_notas          | Critério de seleção das notas
    "! @parameter iv_ocultar_status | X = aplicar filtro de status
    "! @parameter io_repositorio    | Repositório alternativo (testes);
    "!                                padrão: LCL_REPOSITORIO_NOTAS_SAP
    "! @parameter io_exibidor       | Exibidor alternativo (testes);
    "!                                padrão: LCL_EXIBIDOR_ALV
    "! @parameter ro_verificador    | Verificador pronto para uso
    CLASS-METHODS criar
      IMPORTING
        it_notas              TYPE lif_repositorio_notas=>ty_r_nota
        iv_ocultar_status     TYPE abap_bool DEFAULT abap_false
        io_repositorio        TYPE REF TO lif_repositorio_notas OPTIONAL
        io_exibidor           TYPE REF TO lif_exibidor_notas OPTIONAL
      RETURNING
        VALUE(ro_verificador) TYPE REF TO lif_verificador_notas.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_FABRICA_VERIFICADOR - Implementação
*----------------------------------------------------------------------*
CLASS lcl_fabrica_verificador IMPLEMENTATION.

  METHOD criar.

    DATA lo_repositorio TYPE REF TO lif_repositorio_notas.
    DATA lo_exibidor    TYPE REF TO lif_exibidor_notas.

    lo_repositorio = COND #( WHEN io_repositorio IS BOUND
                             THEN io_repositorio
                             ELSE NEW lcl_repositorio_notas_sap( ) ).

    lo_exibidor = COND #( WHEN io_exibidor IS BOUND
                          THEN io_exibidor
                          ELSE NEW lcl_exibidor_alv( ) ).

    ro_verificador = NEW lcl_verificador_notas( it_notas          = it_notas
                                                iv_ocultar_status = iv_ocultar_status
                                                io_repositorio    = lo_repositorio
                                                io_exibidor       = lo_exibidor ).

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe LCL_VERIFICADOR_NOTAS - Implementação
*----------------------------------------------------------------------*
CLASS lcl_verificador_notas IMPLEMENTATION.

  METHOD constructor.
    mt_notas          = it_notas.
    mv_ocultar_status = iv_ocultar_status.
    mo_repositorio    = io_repositorio.
    mo_exibidor       = io_exibidor.
  ENDMETHOD.


  METHOD lif_verificador_notas~executar.

    DATA(lt_saida) = lif_verificador_notas~processar( ).

    IF lt_saida IS INITIAL.
      mo_exibidor->informar_sem_dados( ).
      RETURN.
    ENDIF.

    mo_exibidor->exibir( lt_saida ).

  ENDMETHOD.


  METHOD lif_verificador_notas~processar.

    LOOP AT selecionar_notas( ) INTO DATA(lv_nota).
      APPEND LINES OF processar_nota( lv_nota ) TO rt_saida.
    ENDLOOP.

    rt_saida = remover_repetidas_saida( rt_saida ).

  ENDMETHOD.


  METHOD selecionar_notas.

    " Notas carregadas no sistema que atendem ao critério
    rt_notas = mo_repositorio->selecionar_carregadas( mt_notas ).

    " Valores individuais ainda não carregados também são processados,
    " para que apareçam na lista como "não carregada no sistema"
    LOOP AT mt_notas ASSIGNING FIELD-SYMBOL(<ls_nota>)
         WHERE sign   = 'I'
           AND option = 'EQ'.
      IF <ls_nota>-low IN mt_notas.       " Respeita exclusões (E)
        INSERT <ls_nota>-low INTO TABLE rt_notas.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD processar_nota.

    DATA(ls_nota_principal) = ler_nota_principal( iv_nota ).

    " Nota não carregada: sem instruções de correção não há árvore a
    " determinar (e a busca poderia disparar o download da nota).
    " Nota já concluída (filtro P_OCIMP): pré-requisitos não são
    " relevantes. Em ambos os casos a própria nota permanece na lista
    " para indicar o seu status.
    IF esta_carregada( ls_nota_principal ) = abap_false
       OR deve_ocultar( ls_nota_principal ) = abap_true.
      rt_saida = VALUE #( ( ls_nota_principal ) ).
      RETURN.
    ENDIF.

    DATA(lt_prereq) = ordenar_prerequisitos(
                        it_prereq = mo_repositorio->buscar_prerequisitos( iv_nota )
                        iv_nota   = iv_nota ).

    LOOP AT lt_prereq ASSIGNING FIELD-SYMBOL(<ls_prereq>).
      DATA(ls_linha) = ler_dados_nota( iv_nota           = <ls_prereq>-numm
                                       iv_nota_principal = iv_nota ).
      IF deve_ocultar( ls_linha ) = abap_false.
        APPEND ls_linha TO rt_saida.
      ENDIF.
    ENDLOOP.

    " A nota selecionada é sempre a última linha do seu bloco
    APPEND ls_nota_principal TO rt_saida.

  ENDMETHOD.


  METHOD ler_nota_principal.

    rs_saida = ler_dados_nota( iv_nota           = iv_nota
                               iv_nota_principal = iv_nota ).

    " FNAME vazio = cor aplicada à linha inteira
    rs_saida-t_color = VALUE #( ( fname     = space
                                  color-col = gc_cor_nota_principal
                                  color-int = gc_cor_intensificada
                                  color-inv = 0 ) ).

  ENDMETHOD.


  METHOD deve_ocultar.

    rv_ocultar = xsdbool( mv_ocultar_status = abap_true
                          AND (    is_saida-ntstatus_cod = gc_status_impl_ocultar
                                OR is_saida-prstatus_cod = gc_status_proc_ocultar ) ).

  ENDMETHOD.


  METHOD esta_carregada.
    rv_carregada = xsdbool( is_saida-versno IS NOT INITIAL ).
  ENDMETHOD.


  METHOD ordenar_prerequisitos.

    DATA lt_por_aleid TYPE ty_t_por_aleid.
    DATA lt_ordenacao TYPE ty_t_ordenacao.

    lt_por_aleid = it_prereq.

    " Associa cada nó à sua profundidade na árvore
    lt_ordenacao = VALUE #( FOR ls_nota IN it_prereq
                            ( profundidade = calcular_profundidade( is_nota      = ls_nota
                                                                    it_por_aleid = lt_por_aleid )
                              nota         = ls_nota ) ).

    " Mais profundas primeiro = ordem em que devem ser implementadas
    SORT lt_ordenacao BY profundidade DESCENDING
                         nota-numm    ASCENDING.

    " Remove a própria nota (raiz) e as repetições
    rt_prereq = remover_duplicadas(
                  VALUE #( FOR ls_ordenacao IN lt_ordenacao
                           WHERE ( nota-numm <> iv_nota )
                           ( ls_ordenacao-nota ) ) ).

  ENDMETHOD.


  METHOD calcular_profundidade.

    DATA(lv_pai)    = is_nota-parent_aleid.
    DATA(lv_limite) = lines( it_por_aleid ).  " Proteção contra ciclos

    WHILE lv_pai IS NOT INITIAL AND rv_profundidade < lv_limite.

      READ TABLE it_por_aleid ASSIGNING FIELD-SYMBOL(<ls_pai>)
           WITH TABLE KEY aleid = lv_pai.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.

      rv_profundidade = rv_profundidade + 1.
      lv_pai = <ls_pai>-parent_aleid.

    ENDWHILE.

  ENDMETHOD.


  METHOD remover_duplicadas.

    DATA lt_vistas TYPE HASHED TABLE OF cwb_note_display-numm
                   WITH UNIQUE KEY table_line.

    LOOP AT it_prereq ASSIGNING FIELD-SYMBOL(<ls_nota>).
      INSERT <ls_nota>-numm INTO TABLE lt_vistas.
      IF sy-subrc = 0.
        APPEND <ls_nota> TO rt_prereq.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD remover_repetidas_saida.

    TYPES:
      BEGIN OF lty_s_indice,
        numm  TYPE lif_verificador_notas=>ty_s_saida-numm,
        linha TYPE i,               " Posição da 1ª ocorrência no resultado
      END OF lty_s_indice.

    DATA lt_indice TYPE HASHED TABLE OF lty_s_indice WITH UNIQUE KEY numm.

    LOOP AT it_saida ASSIGNING FIELD-SYMBOL(<ls_saida>).

      READ TABLE lt_indice ASSIGNING FIELD-SYMBOL(<ls_indice>)
           WITH TABLE KEY numm = <ls_saida>-numm.

      IF sy-subrc <> 0.
        " Primeira ocorrência da nota: mantém
        APPEND <ls_saida> TO rt_saida.
        INSERT VALUE #( numm  = <ls_saida>-numm
                        linha = lines( rt_saida ) ) INTO TABLE lt_indice.

      ELSEIF <ls_saida>-t_color IS NOT INITIAL.
        " Repetição removida é uma nota selecionada (destacada):
        " o destaque passa para a ocorrência mantida
        rt_saida[ <ls_indice>-linha ]-t_color = <ls_saida>-t_color.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD ler_dados_nota.

    DATA ls_nota TYPE lif_repositorio_notas=>ty_s_nota.

    TRY.
        ls_nota = mo_repositorio->ler_nota( iv_nota ).
      CATCH lcx_nota_nao_encontrada.
        " Nota não carregada no sistema (SNOTE): exibe apenas o número
        rs_saida = VALUE #( nota_princ = iv_nota_principal
                            numm       = iv_nota
                            ntstatus   = 'Nota não carregada no sistema'(t01) ).
        RETURN.
    ENDTRY.

    rs_saida = VALUE #( nota_princ      = iv_nota_principal
                        numm            = ls_nota-numm
                        versno          = ls_nota-versno
                        themk           = ls_nota-themk
                        langu           = ls_nota-langu
                        stext           = ls_nota-stext
                        ntstatus        = ls_nota-ntstatus_txt
                        prstatus        = ls_nota-prstatus_txt
                        ativ_manual_pre = ls_nota-ativ_manual_pre
                        ativ_manual_pos = ls_nota-ativ_manual_pos
                        ntstatus_cod    = ls_nota-ntstatus_cod
                        prstatus_cod    = ls_nota-prstatus_cod ).

  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Evento principal
*----------------------------------------------------------------------*
START-OF-SELECTION.
  IF s_nota[] IS INITIAL.
    MESSAGE 'Nenhuma informação passada na tela de seleção.'(m02) TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  lcl_fabrica_verificador=>criar( it_notas          = s_nota[]
                                  iv_ocultar_status = p_ocimp )->executar( ).


*======================================================================*
*                          TESTES UNITÁRIOS                            *
*======================================================================*

*----------------------------------------------------------------------*
* Dublê LTD_REPOSITORIO_NOTAS
*----------------------------------------------------------------------*
  "! Repositório em memória: substitui CWBNTHEAD e os FMs da SNOTE.
CLASS ltd_repositorio_notas DEFINITION FINAL FOR TESTING.

  PUBLIC SECTION.

    INTERFACES lif_repositorio_notas.

    "! Registra uma nota como carregada no sistema.
    METHODS adicionar_nota
      IMPORTING
        iv_nota     TYPE cwbntnumm
        iv_ntstatus TYPE lif_repositorio_notas=>ty_s_nota-ntstatus_cod DEFAULT space
        iv_prstatus TYPE lif_repositorio_notas=>ty_s_nota-prstatus_cod DEFAULT space
        iv_ativ_pre TYPE abap_bool DEFAULT abap_false
        iv_ativ_pos TYPE abap_bool DEFAULT abap_false.

    "! Registra a árvore de pré-requisitos de uma nota.
    METHODS adicionar_arvore
      IMPORTING
        iv_nota TYPE cwbntnumm
        it_nos  TYPE tt_cwb_note_display.

    "! Quantidade de chamadas de LER_NOTA para a nota.
    METHODS quantidade_leituras
      IMPORTING
        iv_nota              TYPE cwbntnumm
      RETURNING
        VALUE(rv_quantidade) TYPE i.

    "! Quantidade de chamadas de BUSCAR_PREREQUISITOS para a nota.
    METHODS quantidade_buscas
      IMPORTING
        iv_nota              TYPE cwbntnumm
      RETURNING
        VALUE(rv_quantidade) TYPE i.

  PRIVATE SECTION.

    TYPES:
      BEGIN OF ty_s_arvore,
        numm  TYPE cwbntnumm,
        t_nos TYPE tt_cwb_note_display,
      END OF ty_s_arvore,
      ty_t_chamadas TYPE STANDARD TABLE OF cwbntnumm WITH EMPTY KEY.

    DATA mt_carregadas TYPE lif_repositorio_notas=>ty_t_notas.
    DATA mt_notas      TYPE HASHED TABLE OF lif_repositorio_notas=>ty_s_nota
                       WITH UNIQUE KEY numm.
    DATA mt_arvores    TYPE HASHED TABLE OF ty_s_arvore WITH UNIQUE KEY numm.
    DATA mt_leituras   TYPE ty_t_chamadas.
    DATA mt_buscas     TYPE ty_t_chamadas.

ENDCLASS.

CLASS ltd_repositorio_notas IMPLEMENTATION.

  METHOD adicionar_nota.
    INSERT iv_nota INTO TABLE mt_carregadas.
    INSERT VALUE #( numm            = iv_nota
                    versno          = 1
                    stext           = |Nota { iv_nota }|
                    ntstatus_cod    = iv_ntstatus
                    prstatus_cod    = iv_prstatus
                    ntstatus_txt    = |Impl. { iv_ntstatus }|
                    prstatus_txt    = |Proc. { iv_prstatus }|
                    ativ_manual_pre = iv_ativ_pre
                    ativ_manual_pos = iv_ativ_pos ) INTO TABLE mt_notas.
  ENDMETHOD.


  METHOD adicionar_arvore.
    INSERT VALUE #( numm = iv_nota t_nos = it_nos ) INTO TABLE mt_arvores.
  ENDMETHOD.


  METHOD quantidade_leituras.
    rv_quantidade = REDUCE i( INIT n = 0
                              FOR lv_nota IN mt_leituras WHERE ( table_line = iv_nota )
                              NEXT n = n + 1 ).
  ENDMETHOD.


  METHOD quantidade_buscas.
    rv_quantidade = REDUCE i( INIT n = 0
                              FOR lv_nota IN mt_buscas WHERE ( table_line = iv_nota )
                              NEXT n = n + 1 ).
  ENDMETHOD.


  METHOD lif_repositorio_notas~selecionar_carregadas.
    LOOP AT mt_carregadas INTO DATA(lv_nota).
      IF lv_nota IN it_notas.
        INSERT lv_nota INTO TABLE rt_notas.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD lif_repositorio_notas~ler_nota.
    APPEND iv_nota TO mt_leituras.
    READ TABLE mt_notas INTO rs_nota WITH TABLE KEY numm = iv_nota.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE lcx_nota_nao_encontrada.
    ENDIF.
  ENDMETHOD.


  METHOD lif_repositorio_notas~buscar_prerequisitos.
    APPEND iv_nota TO mt_buscas.
    READ TABLE mt_arvores ASSIGNING FIELD-SYMBOL(<ls_arvore>)
         WITH TABLE KEY numm = iv_nota.
    IF sy-subrc = 0.
      rt_prereq = <ls_arvore>-t_nos.
    ENDIF.
  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Dublê LTD_EXIBIDOR_NOTAS
*----------------------------------------------------------------------*
"! Exibidor espião: registra o que seria exibido, sem ALV nem mensagem.
CLASS ltd_exibidor_notas DEFINITION FINAL FOR TESTING.

  PUBLIC SECTION.
    INTERFACES lif_exibidor_notas.
    DATA mt_exibida           TYPE lif_verificador_notas=>ty_t_saida READ-ONLY.
    DATA mv_exibiu            TYPE abap_bool READ-ONLY.
    DATA mv_informou_sem_dado TYPE abap_bool READ-ONLY.

ENDCLASS.

CLASS ltd_exibidor_notas IMPLEMENTATION.

  METHOD lif_exibidor_notas~exibir.
    mv_exibiu  = abap_true.
    mt_exibida = it_saida.
  ENDMETHOD.


  METHOD lif_exibidor_notas~informar_sem_dados.
    mv_informou_sem_dado = abap_true.
  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Classe de teste LTC_VERIFICADOR_NOTAS
*----------------------------------------------------------------------*
CLASS ltc_verificador_notas DEFINITION FINAL FOR TESTING
  RISK LEVEL HARMLESS
  DURATION SHORT.

  PRIVATE SECTION.

    TYPES ty_t_numm TYPE STANDARD TABLE OF cwbntnumm WITH EMPTY KEY.

    CONSTANTS:
      gc_n100      TYPE cwbntnumm VALUE '0000000100',
      gc_n200      TYPE cwbntnumm VALUE '0000000200',
      gc_n300      TYPE cwbntnumm VALUE '0000000300',
      gc_n400      TYPE cwbntnumm VALUE '0000000400',
      gc_n900      TYPE cwbntnumm VALUE '0000000900',
      gc_impl_conc TYPE bcwbn_note-customer_attributes-ntstatus VALUE 'A',
      gc_proc_conc TYPE bcwbn_note-customer_attributes-prstatus VALUE 'E'.

    DATA mo_repositorio TYPE REF TO ltd_repositorio_notas.
    DATA mo_exibidor    TYPE REF TO ltd_exibidor_notas.

    METHODS setup.

    " Auxiliares
    METHODS criar_verificador
      IMPORTING
        it_notas              TYPE lif_repositorio_notas=>ty_r_nota
        iv_ocultar            TYPE abap_bool DEFAULT abap_false
      RETURNING
        VALUE(ro_verificador) TYPE REF TO lif_verificador_notas.
    METHODS r_nota
      IMPORTING
        iv_nota         TYPE cwbntnumm
      RETURNING
        VALUE(rt_notas) TYPE lif_repositorio_notas=>ty_r_nota.
    METHODS no
      IMPORTING
        iv_aleid     TYPE cwb_note_display-aleid
        iv_pai       TYPE cwb_note_display-parent_aleid OPTIONAL
        iv_nota      TYPE cwbntnumm
      RETURNING
        VALUE(rs_no) TYPE cwb_note_display.
    METHODS notas_da_saida
      IMPORTING
        it_saida        TYPE lif_verificador_notas=>ty_t_saida
      RETURNING
        VALUE(rt_notas) TYPE ty_t_numm.

    " Seleção
    METHODS selecao_inclui_nao_carregada FOR TESTING.
    METHODS selecao_respeita_exclusao    FOR TESTING.
    " Ordenação e estrutura dos blocos
    METHODS ordena_por_profundidade      FOR TESTING.
    METHODS empate_ordena_por_numero     FOR TESTING.
    METHODS principal_ultima_e_destacada FOR TESTING.
    METHODS remove_repetidas_na_arvore   FOR TESTING.
    METHODS nao_le_mesma_nota_duas_vezes FOR TESTING.
    METHODS arvore_vazia_so_principal    FOR TESTING.
    METHODS ciclo_nao_trava              FOR TESTING.
    METHODS nota_nao_carregada           FOR TESTING.
    METHODS nao_carregada_sem_busca      FOR TESTING.
    " Atividades manuais
    METHODS ativ_manuais_na_saida        FOR TESTING.
    " Filtro P_OCIMP
    METHODS filtro_oculta_prereq_impl    FOR TESTING.
    METHODS filtro_oculta_prereq_proc    FOR TESTING.
    METHODS filtro_desligado_mantem_tudo FOR TESTING.
    METHODS principal_concl_sem_prereq   FOR TESTING.
    " Limpeza final
    METHODS repetida_entre_blocos        FOR TESTING.
    METHODS destaque_transferido         FOR TESTING.
    " Execução e fábrica
    METHODS executar_exibe_resultado     FOR TESTING.
    METHODS executar_sem_dados_informa   FOR TESTING.
    METHODS fabrica_cria_instancia       FOR TESTING.

ENDCLASS.

CLASS ltc_verificador_notas IMPLEMENTATION.

  METHOD setup.
    mo_repositorio = NEW #( ).
    mo_exibidor    = NEW #( ).
  ENDMETHOD.


  METHOD criar_verificador.
    ro_verificador = lcl_fabrica_verificador=>criar( it_notas          = it_notas
                                                     iv_ocultar_status = iv_ocultar
                                                     io_repositorio    = mo_repositorio
                                                     io_exibidor       = mo_exibidor ).
  ENDMETHOD.


  METHOD r_nota.
    rt_notas = VALUE #( ( sign = 'I' option = 'EQ' low = iv_nota ) ).
  ENDMETHOD.


  METHOD no.
    rs_no = VALUE #( aleid = iv_aleid parent_aleid = iv_pai numm = iv_nota ).
  ENDMETHOD.


  METHOD notas_da_saida.
    rt_notas = VALUE #( FOR ls_saida IN it_saida ( ls_saida-numm ) ).
  ENDMETHOD.


  METHOD selecao_inclui_nao_carregada.

    mo_repositorio->adicionar_nota( gc_n100 ).

    DATA(lt_saida) = criar_verificador(
                       VALUE #( ( sign = 'I' option = 'EQ' low = gc_n100 )
                                ( sign = 'I' option = 'EQ' low = gc_n900 ) ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n100 ) ( gc_n900 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Nota I/EQ não carregada deve ser processada' ).

  ENDMETHOD.


  METHOD selecao_respeita_exclusao.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n300 ).

    DATA(lt_saida) = criar_verificador(
                       VALUE #( ( sign = 'I' option = 'BT' low = gc_n100 high = gc_n400 )
                                ( sign = 'E' option = 'EQ' low = gc_n200 ) ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n100 ) ( gc_n300 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Notas excluídas (E) não devem ser processadas' ).

  ENDMETHOD.


  METHOD ordena_por_profundidade.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '2' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n300 ) ( gc_n200 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Mais profundas devem vir primeiro' ).

  ENDMETHOD.


  METHOD empate_ordena_por_numero.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n400 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n400 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n200 ) ( gc_n400 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Mesma profundidade: ordem crescente de número' ).

  ENDMETHOD.


  METHOD principal_ultima_e_destacada.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lt_saida ) ).
    cl_abap_unit_assert=>assert_equals( exp = gc_n100 act = lt_saida[ 2 ]-numm
                                        msg = 'Nota selecionada deve ser a última do bloco' ).
    cl_abap_unit_assert=>assert_not_initial( act = lt_saida[ 2 ]-t_color
                                             msg = 'Nota selecionada deve estar destacada' ).
    cl_abap_unit_assert=>assert_initial( act = lt_saida[ 1 ]-t_color
                                         msg = 'Pré-requisito não deve estar destacado' ).
    cl_abap_unit_assert=>assert_equals( exp = gc_n100 act = lt_saida[ 1 ]-nota_princ
                                        msg = 'Pré-requisito deve indicar a nota do bloco' ).

  ENDMETHOD.


  METHOD remove_repetidas_na_arvore.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '2' iv_nota = gc_n300 ) )
                                                         ( no( iv_aleid = '4' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n300 ) ( gc_n200 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Nota repetida na árvore deve aparecer uma vez, na posição mais profunda' ).

  ENDMETHOD.


  METHOD nao_le_mesma_nota_duas_vezes.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n300 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '4' iv_pai = '3' iv_nota = gc_n300 ) ) ) ).

    criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals( exp = 1
                                        act = mo_repositorio->quantidade_leituras( gc_n300 )
                                        msg = 'Nota repetida na árvore deve ser lida uma única vez' ).

  ENDMETHOD.


  METHOD arvore_vazia_so_principal.

    mo_repositorio->adicionar_nota( gc_n100 ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Sem árvore, apenas a própria nota é exibida' ).

  ENDMETHOD.


  METHOD ciclo_nao_trava.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    " Nós 2 e 3 apontam um para o outro
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '3' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '2' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n200 ) ( gc_n300 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Referência cíclica deve ser tratada sem laço infinito' ).

  ENDMETHOD.


  METHOD nota_nao_carregada.

    DATA(lt_saida) = criar_verificador( r_nota( gc_n900 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt_saida ) ).
    cl_abap_unit_assert=>assert_equals( exp = gc_n900 act = lt_saida[ 1 ]-numm ).
    cl_abap_unit_assert=>assert_initial( act = lt_saida[ 1 ]-versno
                                         msg = 'Nota não carregada não possui versão' ).
    cl_abap_unit_assert=>assert_not_initial( act = lt_saida[ 1 ]-ntstatus
                                             msg = 'Deve indicar que a nota não está carregada' ).
    cl_abap_unit_assert=>assert_not_initial( act = lt_saida[ 1 ]-t_color
                                             msg = 'Nota selecionada deve estar destacada' ).

  ENDMETHOD.


  METHOD nao_carregada_sem_busca.

    " Mesmo que houvesse árvore registrada, a nota não carregada não
    " deve disparar a busca de pré-requisitos
    mo_repositorio->adicionar_arvore( iv_nota = gc_n900
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n900 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n900 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n900 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Nota não carregada deve ser exibida sozinha' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 0
      act = mo_repositorio->quantidade_buscas( gc_n900 )
      msg = 'Árvore de nota não carregada não deve ser buscada' ).

  ENDMETHOD.


  METHOD ativ_manuais_na_saida.

    mo_repositorio->adicionar_nota( iv_nota = gc_n100 iv_ativ_pos = abap_true ).
    mo_repositorio->adicionar_nota( iv_nota = gc_n200 iv_ativ_pre = abap_true ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( lt_saida ) ).
    cl_abap_unit_assert=>assert_true( act = lt_saida[ 1 ]-ativ_manual_pre
                                      msg = 'Atividade manual pré do pré-requisito deve ser exibida' ).
    cl_abap_unit_assert=>assert_false( act = lt_saida[ 1 ]-ativ_manual_pos
                                       msg = 'Pré-requisito não possui atividade manual pós' ).
    cl_abap_unit_assert=>assert_false( act = lt_saida[ 2 ]-ativ_manual_pre
                                       msg = 'Nota principal não possui atividade manual pré' ).
    cl_abap_unit_assert=>assert_true( act = lt_saida[ 2 ]-ativ_manual_pos
                                      msg = 'Atividade manual pós da nota principal deve ser exibida' ).

  ENDMETHOD.


  METHOD filtro_oculta_prereq_impl.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( iv_nota = gc_n200 iv_ntstatus = gc_impl_conc ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( it_notas   = r_nota( gc_n100 )
                                        iv_ocultar = abap_true )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n300 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Pré-requisito com status de implementação A deve ser ocultado' ).

  ENDMETHOD.


  METHOD filtro_oculta_prereq_proc.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( iv_nota = gc_n200 iv_prstatus = gc_proc_conc ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( it_notas   = r_nota( gc_n100 )
                                        iv_ocultar = abap_true )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n300 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Pré-requisito com status de processamento E deve ser ocultado' ).

  ENDMETHOD.


  METHOD filtro_desligado_mantem_tudo.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( iv_nota = gc_n200 iv_ntstatus = gc_impl_conc ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) )
                                                         ( no( iv_aleid = '3' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador( r_nota( gc_n100 ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n200 ) ( gc_n300 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Sem filtro, todas as notas devem ser exibidas' ).

  ENDMETHOD.


  METHOD principal_concl_sem_prereq.

    mo_repositorio->adicionar_nota( iv_nota = gc_n100 iv_ntstatus = gc_impl_conc ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador( it_notas   = r_nota( gc_n100 )
                                        iv_ocultar = abap_true )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n100 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Nota selecionada concluída deve ser exibida sozinha' ).
    cl_abap_unit_assert=>assert_equals(
      exp = 0
      act = mo_repositorio->quantidade_buscas( gc_n100 )
      msg = 'Árvore de pré-requisitos não deve ser buscada' ).

  ENDMETHOD.


  METHOD repetida_entre_blocos.

    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n300 ).
    mo_repositorio->adicionar_nota( gc_n400 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n400
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n400 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n300 ) ) ) ).

    DATA(lt_saida) = criar_verificador(
                       VALUE #( ( sign = 'I' option = 'EQ' low = gc_n100 )
                                ( sign = 'I' option = 'EQ' low = gc_n400 ) ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n300 ) ( gc_n100 ) ( gc_n400 ) )
      act = notas_da_saida( lt_saida )
      msg = 'Pré-requisito comum deve aparecer só no primeiro bloco' ).

  ENDMETHOD.


  METHOD destaque_transferido.

    " 200 é selecionada e também pré-requisito de 100
    mo_repositorio->adicionar_nota( gc_n100 ).
    mo_repositorio->adicionar_nota( gc_n200 ).
    mo_repositorio->adicionar_arvore( iv_nota = gc_n100
                                      it_nos  = VALUE #( ( no( iv_aleid = '1' iv_nota = gc_n100 ) )
                                                         ( no( iv_aleid = '2' iv_pai = '1' iv_nota = gc_n200 ) ) ) ).

    DATA(lt_saida) = criar_verificador(
                       VALUE #( ( sign = 'I' option = 'EQ' low = gc_n100 )
                                ( sign = 'I' option = 'EQ' low = gc_n200 ) ) )->processar( ).

    cl_abap_unit_assert=>assert_equals(
      exp = VALUE ty_t_numm( ( gc_n200 ) ( gc_n100 ) )
      act = notas_da_saida( lt_saida ) ).
    cl_abap_unit_assert=>assert_not_initial(
      act = lt_saida[ 1 ]-t_color
      msg = 'Destaque da nota selecionada deve passar para a ocorrência mantida' ).

  ENDMETHOD.


  METHOD executar_exibe_resultado.

    mo_repositorio->adicionar_nota( gc_n100 ).

    criar_verificador( r_nota( gc_n100 ) )->executar( ).

    cl_abap_unit_assert=>assert_true( act = mo_exibidor->mv_exibiu
                                      msg = 'Resultado deve ser exibido' ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( mo_exibidor->mt_exibida ) ).
    cl_abap_unit_assert=>assert_false( mo_exibidor->mv_informou_sem_dado ).

  ENDMETHOD.


  METHOD executar_sem_dados_informa.

    " Intervalo sem notas carregadas e sem valores individuais
    criar_verificador(
      VALUE #( ( sign = 'I' option = 'BT' low = gc_n100 high = gc_n400 ) ) )->executar( ).

    cl_abap_unit_assert=>assert_true( act = mo_exibidor->mv_informou_sem_dado
                                      msg = 'Deve informar ausência de notas' ).
    cl_abap_unit_assert=>assert_false( act = mo_exibidor->mv_exibiu
                                       msg = 'ALV não deve ser exibido sem dados' ).

  ENDMETHOD.


  METHOD fabrica_cria_instancia.

    " Sem dublês: a fábrica monta as dependências produtivas
    " (nenhum acesso a banco ocorre apenas na criação)
    DATA(lo_verificador) = lcl_fabrica_verificador=>criar( it_notas = r_nota( gc_n100 ) ).

    cl_abap_unit_assert=>assert_bound( lo_verificador ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lo_verificador IS INSTANCE OF lcl_verificador_notas )
      msg = 'Fábrica deve criar LCL_VERIFICADOR_NOTAS' ).

  ENDMETHOD.

ENDCLASS.
