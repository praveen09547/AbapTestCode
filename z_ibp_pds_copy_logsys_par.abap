FUNCTION z_ibp_pds_copy_logsys_par.
*"----------------------------------------------------------------------
*" Remote-Enabled Module (RFC)  -  processing type: "Remote"
*"
*" Worker for report ZIBP_PDS_COPY_LOGSYS.  Receives one package of
*" source rows of exactly one IBP sourcing table, overwrites the logical
*" system with the target value and inserts the copies.  Runs in its own
*" work process / LUW under the SPBT framework.
*"
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_SOURCE_LOGSYS) TYPE  LOGSYS
*"     VALUE(IV_TARGET_LOGSYS) TYPE  LOGSYS
*"     VALUE(IV_TABLE) TYPE  TABNAME
*"  EXPORTING
*"     VALUE(EV_INSERTED) TYPE  I
*"     VALUE(EV_TABLE) TYPE  TABNAME
*"  TABLES
*"      IT_SOSHEAD STRUCTURE  /IBP/SOSHEAD_EXT OPTIONAL
*"      IT_SOSBOM STRUCTURE  /IBP/SOSBOM_EXT OPTIONAL
*"      IT_SOSACT STRUCTURE  /IBP/SOSACT_EXT OPTIONAL
*"  EXCEPTIONS
*"      INSERT_FAILED
*"----------------------------------------------------------------------

  ev_table    = iv_table.
  ev_inserted = 0.

  CASE iv_table.

    WHEN '/IBP/SOSHEAD_EXT'.
      LOOP AT it_soshead ASSIGNING FIELD-SYMBOL(<head>).
        <head>-logsys = iv_target_logsys.
      ENDLOOP.
      IF it_soshead[] IS NOT INITIAL.
        INSERT /ibp/soshead_ext FROM TABLE it_soshead[].
        IF sy-subrc <> 0.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_soshead[] ).
      ENDIF.

    WHEN '/IBP/SOSBOM_EXT'.
      LOOP AT it_sosbom ASSIGNING FIELD-SYMBOL(<bom>).
        <bom>-logsys = iv_target_logsys.
      ENDLOOP.
      IF it_sosbom[] IS NOT INITIAL.
        INSERT /ibp/sosbom_ext FROM TABLE it_sosbom[].
        IF sy-subrc <> 0.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_sosbom[] ).
      ENDIF.

    WHEN '/IBP/SOSACT_EXT'.
      LOOP AT it_sosact ASSIGNING FIELD-SYMBOL(<act>).
        <act>-logsys = iv_target_logsys.
      ENDLOOP.
      IF it_sosact[] IS NOT INITIAL.
        INSERT /ibp/sosact_ext FROM TABLE it_sosact[].
        IF sy-subrc <> 0.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_sosact[] ).
      ENDIF.

  ENDCASE.

  " Each parallel task owns its own LUW - commit the inserted package.
  COMMIT WORK AND WAIT.

ENDFUNCTION.
