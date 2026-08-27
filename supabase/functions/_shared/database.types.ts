export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.17"
  }
  public: {
    Tables: {
      ai_ingestion_jobs: {
        Row: {
          cards_generated_count: number
          created_at: string
          deck_id: string
          deleted_at: string | null
          error_message: string | null
          id: string
          notes_generated_count: number
          source_reference: string | null
          source_type: Database["public"]["Enums"]["generation_source_type"]
          status: Database["public"]["Enums"]["job_status_type"]
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          cards_generated_count?: number
          created_at?: string
          deck_id: string
          deleted_at?: string | null
          error_message?: string | null
          id?: string
          notes_generated_count?: number
          source_reference?: string | null
          source_type: Database["public"]["Enums"]["generation_source_type"]
          status?: Database["public"]["Enums"]["job_status_type"]
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          cards_generated_count?: number
          created_at?: string
          deck_id?: string
          deleted_at?: string | null
          error_message?: string | null
          id?: string
          notes_generated_count?: number
          source_reference?: string | null
          source_type?: Database["public"]["Enums"]["generation_source_type"]
          status?: Database["public"]["Enums"]["job_status_type"]
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "ai_ingestion_jobs_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      anki_transfer_jobs: {
        Row: {
          completed_at: string | null
          direction: string
          error_message: string | null
          file_sha256: string | null
          id: string
          imported_cards: number
          imported_notes: number
          options: Json
          requested_at: string
          skipped_notes: number
          source_deck_id: string | null
          started_at: string | null
          status: string
          storage_path: string | null
          target_deck_id: string | null
          total_notes: number
          user_id: string
          usn: number
        }
        Insert: {
          completed_at?: string | null
          direction: string
          error_message?: string | null
          file_sha256?: string | null
          id?: string
          imported_cards?: number
          imported_notes?: number
          options?: Json
          requested_at?: string
          skipped_notes?: number
          source_deck_id?: string | null
          started_at?: string | null
          status?: string
          storage_path?: string | null
          target_deck_id?: string | null
          total_notes?: number
          user_id: string
          usn?: number
        }
        Update: {
          completed_at?: string | null
          direction?: string
          error_message?: string | null
          file_sha256?: string | null
          id?: string
          imported_cards?: number
          imported_notes?: number
          options?: Json
          requested_at?: string
          skipped_notes?: number
          source_deck_id?: string | null
          started_at?: string | null
          status?: string
          storage_path?: string | null
          target_deck_id?: string | null
          total_notes?: number
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "anki_transfer_jobs_source_deck_id_fkey"
            columns: ["source_deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "anki_transfer_jobs_target_deck_id_fkey"
            columns: ["target_deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      badges_definition: {
        Row: {
          code_name: string
          created_at: string
          description: string | null
          display_name: string
          icon_url: string | null
          id: string
          xp_requirement: number
        }
        Insert: {
          code_name: string
          created_at?: string
          description?: string | null
          display_name: string
          icon_url?: string | null
          id?: string
          xp_requirement?: number
        }
        Update: {
          code_name?: string
          created_at?: string
          description?: string | null
          display_name?: string
          icon_url?: string | null
          id?: string
          xp_requirement?: number
        }
        Relationships: []
      }
      card_learning_state: {
        Row: {
          algorithm: Database["public"]["Enums"]["srs_algorithm"]
          algorithm_state: Json
          card_id: string
          created_at: string
          difficulty: number | null
          due_at: string
          ease_factor: number | null
          fsrs_last_scheduled_at: string | null
          fsrs_retrievability: number | null
          fsrs_state: number
          fsrs_step: number | null
          fsrs_version: string
          id: string
          interval_days: number
          is_suspended: boolean
          lapses: number
          last_reviewed_at: string | null
          reps: number
          stability: number | null
          state: Database["public"]["Enums"]["card_state"]
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          algorithm_state?: Json
          card_id: string
          created_at?: string
          difficulty?: number | null
          due_at?: string
          ease_factor?: number | null
          fsrs_last_scheduled_at?: string | null
          fsrs_retrievability?: number | null
          fsrs_state?: number
          fsrs_step?: number | null
          fsrs_version?: string
          id?: string
          interval_days?: number
          is_suspended?: boolean
          lapses?: number
          last_reviewed_at?: string | null
          reps?: number
          stability?: number | null
          state?: Database["public"]["Enums"]["card_state"]
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          algorithm_state?: Json
          card_id?: string
          created_at?: string
          difficulty?: number | null
          due_at?: string
          ease_factor?: number | null
          fsrs_last_scheduled_at?: string | null
          fsrs_retrievability?: number | null
          fsrs_state?: number
          fsrs_step?: number | null
          fsrs_version?: string
          id?: string
          interval_days?: number
          is_suspended?: boolean
          lapses?: number
          last_reviewed_at?: string | null
          reps?: number
          stability?: number | null
          state?: Database["public"]["Enums"]["card_state"]
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "card_learning_state_card_id_fkey"
            columns: ["card_id"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["id"]
          },
        ]
      }
      card_media: {
        Row: {
          card_id: string
          created_at: string
          field_name: string | null
          file_size_bytes: number | null
          id: string
          md5_hash: string | null
          media_type: Database["public"]["Enums"]["media_type"]
          metadata: Json
          mime_type: string | null
          sha256_hash: string | null
          storage_bucket: string
          storage_path: string
          user_id: string
          usn: number
        }
        Insert: {
          card_id: string
          created_at?: string
          field_name?: string | null
          file_size_bytes?: number | null
          id?: string
          md5_hash?: string | null
          media_type: Database["public"]["Enums"]["media_type"]
          metadata?: Json
          mime_type?: string | null
          sha256_hash?: string | null
          storage_bucket?: string
          storage_path: string
          user_id: string
          usn?: number
        }
        Update: {
          card_id?: string
          created_at?: string
          field_name?: string | null
          file_size_bytes?: number | null
          id?: string
          md5_hash?: string | null
          media_type?: Database["public"]["Enums"]["media_type"]
          metadata?: Json
          mime_type?: string | null
          sha256_hash?: string | null
          storage_bucket?: string
          storage_path?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "card_media_card_id_fkey"
            columns: ["card_id"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["id"]
          },
        ]
      }
      card_tags: {
        Row: {
          card_id: string
          tag_id: string
          usn: number
        }
        Insert: {
          card_id: string
          tag_id: string
          usn?: number
        }
        Update: {
          card_id?: string
          tag_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "card_tags_card_id_fkey"
            columns: ["card_id"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "card_tags_tag_id_fkey"
            columns: ["tag_id"]
            isOneToOne: false
            referencedRelation: "tags"
            referencedColumns: ["id"]
          },
        ]
      }
      card_templates: {
        Row: {
          card_generation: Json
          created_at: string
          field_definitions: Json
          id: string
          is_system: boolean
          name: string
          updated_at: string
          user_id: string | null
          usn: number
        }
        Insert: {
          card_generation?: Json
          created_at?: string
          field_definitions?: Json
          id?: string
          is_system?: boolean
          name: string
          updated_at?: string
          user_id?: string | null
          usn?: number
        }
        Update: {
          card_generation?: Json
          created_at?: string
          field_definitions?: Json
          id?: string
          is_system?: boolean
          name?: string
          updated_at?: string
          user_id?: string | null
          usn?: number
        }
        Relationships: []
      }
      cards: {
        Row: {
          card_kind: string
          card_ordinal: number
          cloze_ordinal: number | null
          created_at: string
          deck_id: string
          deleted_at: string | null
          fields: Json
          id: string
          is_archived: boolean
          note_group_id: string
          note_id: string
          template_id: string | null
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          card_kind?: string
          card_ordinal?: number
          cloze_ordinal?: number | null
          created_at?: string
          deck_id: string
          deleted_at?: string | null
          fields?: Json
          id?: string
          is_archived?: boolean
          note_group_id?: string
          note_id: string
          template_id?: string | null
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          card_kind?: string
          card_ordinal?: number
          cloze_ordinal?: number | null
          created_at?: string
          deck_id?: string
          deleted_at?: string | null
          fields?: Json
          id?: string
          is_archived?: boolean
          note_group_id?: string
          note_id?: string
          template_id?: string | null
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "cards_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cards_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "notes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cards_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "card_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      daily_statistics: {
        Row: {
          cards_studied: number
          correct_count: number
          incorrect_count: number
          new_cards_studied: number
          reviews_count: number
          stat_date: string
          time_studied_ms: number
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          cards_studied?: number
          correct_count?: number
          incorrect_count?: number
          new_cards_studied?: number
          reviews_count?: number
          stat_date: string
          time_studied_ms?: number
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          cards_studied?: number
          correct_count?: number
          incorrect_count?: number
          new_cards_studied?: number
          reviews_count?: number
          stat_date?: string
          time_studied_ms?: number
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      deck_collaborators: {
        Row: {
          created_at: string
          deck_id: string
          role: Database["public"]["Enums"]["collaborator_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          deck_id: string
          role?: Database["public"]["Enums"]["collaborator_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          deck_id?: string
          role?: Database["public"]["Enums"]["collaborator_role"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "deck_collaborators_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      deck_exams: {
        Row: {
          created_at: string
          deck_id: string
          exam_name: string
          id: string
          priority_level: Database["public"]["Enums"]["exam_priority_level"]
          status: string
          target_date: string
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          created_at?: string
          deck_id: string
          exam_name: string
          id?: string
          priority_level?: Database["public"]["Enums"]["exam_priority_level"]
          status?: string
          target_date: string
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          created_at?: string
          deck_id?: string
          exam_name?: string
          id?: string
          priority_level?: Database["public"]["Enums"]["exam_priority_level"]
          status?: string
          target_date?: string
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "deck_exams_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      decks: {
        Row: {
          created_at: string
          deleted_at: string | null
          description: string | null
          icon: string | null
          id: string
          is_archived: boolean
          name: string
          parent_deck_id: string | null
          study_config: Json
          updated_at: string
          user_id: string
          usn: number
          visibility: Database["public"]["Enums"]["deck_visibility"]
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          icon?: string | null
          id?: string
          is_archived?: boolean
          name: string
          parent_deck_id?: string | null
          study_config?: Json
          updated_at?: string
          user_id: string
          usn?: number
          visibility?: Database["public"]["Enums"]["deck_visibility"]
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          icon?: string | null
          id?: string
          is_archived?: boolean
          name?: string
          parent_deck_id?: string | null
          study_config?: Json
          updated_at?: string
          user_id?: string
          usn?: number
          visibility?: Database["public"]["Enums"]["deck_visibility"]
        }
        Relationships: [
          {
            foreignKeyName: "decks_parent_deck_id_fkey"
            columns: ["parent_deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      fsrs_optimization_runs: {
        Row: {
          completed_at: string | null
          error_message: string | null
          id: string
          new_loss: number | null
          new_weights: number[]
          old_loss: number | null
          old_weights: number[]
          requested_at: string
          source_review_count: number
          started_at: string | null
          status: string
          user_id: string
          usn: number
        }
        Insert: {
          completed_at?: string | null
          error_message?: string | null
          id?: string
          new_loss?: number | null
          new_weights?: number[]
          old_loss?: number | null
          old_weights?: number[]
          requested_at?: string
          source_review_count: number
          started_at?: string | null
          status?: string
          user_id: string
          usn?: number
        }
        Update: {
          completed_at?: string | null
          error_message?: string | null
          id?: string
          new_loss?: number | null
          new_weights?: number[]
          old_loss?: number | null
          old_weights?: number[]
          requested_at?: string
          source_review_count?: number
          started_at?: string | null
          status?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      graves: {
        Row: {
          created_at: string
          deleted_at: string
          entity_key: string
          entity_type: string
          id: string
          user_id: string
          usn: number
        }
        Insert: {
          created_at?: string
          deleted_at?: string
          entity_key: string
          entity_type: string
          id?: string
          user_id: string
          usn: number
        }
        Update: {
          created_at?: string
          deleted_at?: string
          entity_key?: string
          entity_type?: string
          id?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      mcp_tool_audit: {
        Row: {
          created_at: string
          id: string
          input_hash: string | null
          request_id: string | null
          result_count: number | null
          tool_name: string
          user_id: string
          usn: number
        }
        Insert: {
          created_at?: string
          id?: string
          input_hash?: string | null
          request_id?: string | null
          result_count?: number | null
          tool_name: string
          user_id: string
          usn?: number
        }
        Update: {
          created_at?: string
          id?: string
          input_hash?: string | null
          request_id?: string | null
          result_count?: number | null
          tool_name?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      note_card_definitions: {
        Row: {
          back_template: string
          card_kind: string
          cloze_ordinal: number | null
          created_at: string
          front_template: string
          id: string
          name: string
          ordinal: number
          template_id: string
          updated_at: string
          usn: number
        }
        Insert: {
          back_template: string
          card_kind?: string
          cloze_ordinal?: number | null
          created_at?: string
          front_template: string
          id?: string
          name: string
          ordinal: number
          template_id: string
          updated_at?: string
          usn?: number
        }
        Update: {
          back_template?: string
          card_kind?: string
          cloze_ordinal?: number | null
          created_at?: string
          front_template?: string
          id?: string
          name?: string
          ordinal?: number
          template_id?: string
          updated_at?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_card_definitions_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "card_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      note_cloze_deletions: {
        Row: {
          cloze_ordinal: number
          created_at: string
          end_offset: number | null
          field_name: string
          hint: string | null
          id: string
          note_id: string
          start_offset: number | null
          updated_at: string
          usn: number
        }
        Insert: {
          cloze_ordinal: number
          created_at?: string
          end_offset?: number | null
          field_name: string
          hint?: string | null
          id?: string
          note_id: string
          start_offset?: number | null
          updated_at?: string
          usn?: number
        }
        Update: {
          cloze_ordinal?: number
          created_at?: string
          end_offset?: number | null
          field_name?: string
          hint?: string | null
          id?: string
          note_id?: string
          start_offset?: number | null
          updated_at?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_cloze_deletions_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "notes"
            referencedColumns: ["id"]
          },
        ]
      }
      note_image_occlusion_boxes: {
        Row: {
          cloze_ordinal: number
          created_at: string
          height_pct: number
          id: string
          label_text: string | null
          metadata: Json
          note_id: string
          usn: number
          width_pct: number
          x_pos: number
          y_pos: number
        }
        Insert: {
          cloze_ordinal: number
          created_at?: string
          height_pct: number
          id?: string
          label_text?: string | null
          metadata?: Json
          note_id: string
          usn?: number
          width_pct: number
          x_pos: number
          y_pos: number
        }
        Update: {
          cloze_ordinal?: number
          created_at?: string
          height_pct?: number
          id?: string
          label_text?: string | null
          metadata?: Json
          note_id?: string
          usn?: number
          width_pct?: number
          x_pos?: number
          y_pos?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_image_occlusion_boxes_note_id_fkey"
            columns: ["note_id"]
            isOneToOne: false
            referencedRelation: "notes"
            referencedColumns: ["id"]
          },
        ]
      }
      note_references: {
        Row: {
          block_id: string | null
          context_snippet: string | null
          created_at: string
          id: string
          source_note_id: string
          target_note_id: string
          usn: number
        }
        Insert: {
          block_id?: string | null
          context_snippet?: string | null
          created_at?: string
          id?: string
          source_note_id: string
          target_note_id: string
          usn?: number
        }
        Update: {
          block_id?: string | null
          context_snippet?: string | null
          created_at?: string
          id?: string
          source_note_id?: string
          target_note_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "note_references_source_note_id_fkey"
            columns: ["source_note_id"]
            isOneToOne: false
            referencedRelation: "notes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "note_references_target_note_id_fkey"
            columns: ["target_note_id"]
            isOneToOne: false
            referencedRelation: "notes"
            referencedColumns: ["id"]
          },
        ]
      }
      notes: {
        Row: {
          content_hash: string | null
          created_at: string
          deck_id: string
          deleted_at: string | null
          embedding: string | null
          embedding_content_hash: string | null
          embedding_model: string | null
          embedding_updated_at: string | null
          external_id: string | null
          fields: Json
          id: string
          search_document: unknown
          source: string | null
          source_format: string
          template_id: string | null
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          content_hash?: string | null
          created_at?: string
          deck_id: string
          deleted_at?: string | null
          embedding?: string | null
          embedding_content_hash?: string | null
          embedding_model?: string | null
          embedding_updated_at?: string | null
          external_id?: string | null
          fields?: Json
          id?: string
          search_document?: unknown
          source?: string | null
          source_format?: string
          template_id?: string | null
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          content_hash?: string | null
          created_at?: string
          deck_id?: string
          deleted_at?: string | null
          embedding?: string | null
          embedding_content_hash?: string | null
          embedding_model?: string | null
          embedding_updated_at?: string | null
          external_id?: string | null
          fields?: Json
          id?: string
          search_document?: unknown
          source?: string | null
          source_format?: string
          template_id?: string | null
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "notes_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "card_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          display_name: string | null
          id: string
          language: string
          settings: Json
          timezone: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          display_name?: string | null
          id: string
          language?: string
          settings?: Json
          timezone?: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          language?: string
          settings?: Json
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      review_logs: {
        Row: {
          algorithm: Database["public"]["Enums"]["srs_algorithm"]
          card_id: string
          client_review_id: string | null
          created_at: string
          device_id: string | null
          elapsed_days: number | null
          fsrs_parameter_version: number | null
          fsrs_retrievability: number | null
          fsrs_version: string
          id: string
          new_difficulty: number | null
          new_due_at: string
          new_ease_factor: number | null
          new_interval_days: number | null
          new_stability: number | null
          new_state: Database["public"]["Enums"]["card_state"]
          prev_difficulty: number | null
          prev_due_at: string | null
          prev_ease_factor: number | null
          prev_interval_days: number | null
          prev_stability: number | null
          prev_state: Database["public"]["Enums"]["card_state"] | null
          rating: Database["public"]["Enums"]["review_rating"]
          reviewed_at: string
          scheduled_days: number | null
          session_id: string | null
          time_spent_ms: number | null
          user_id: string
          usn: number
        }
        Insert: {
          algorithm: Database["public"]["Enums"]["srs_algorithm"]
          card_id: string
          client_review_id?: string | null
          created_at?: string
          device_id?: string | null
          elapsed_days?: number | null
          fsrs_parameter_version?: number | null
          fsrs_retrievability?: number | null
          fsrs_version?: string
          id?: string
          new_difficulty?: number | null
          new_due_at: string
          new_ease_factor?: number | null
          new_interval_days?: number | null
          new_stability?: number | null
          new_state: Database["public"]["Enums"]["card_state"]
          prev_difficulty?: number | null
          prev_due_at?: string | null
          prev_ease_factor?: number | null
          prev_interval_days?: number | null
          prev_stability?: number | null
          prev_state?: Database["public"]["Enums"]["card_state"] | null
          rating: Database["public"]["Enums"]["review_rating"]
          reviewed_at?: string
          scheduled_days?: number | null
          session_id?: string | null
          time_spent_ms?: number | null
          user_id: string
          usn?: number
        }
        Update: {
          algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          card_id?: string
          client_review_id?: string | null
          created_at?: string
          device_id?: string | null
          elapsed_days?: number | null
          fsrs_parameter_version?: number | null
          fsrs_retrievability?: number | null
          fsrs_version?: string
          id?: string
          new_difficulty?: number | null
          new_due_at?: string
          new_ease_factor?: number | null
          new_interval_days?: number | null
          new_stability?: number | null
          new_state?: Database["public"]["Enums"]["card_state"]
          prev_difficulty?: number | null
          prev_due_at?: string | null
          prev_ease_factor?: number | null
          prev_interval_days?: number | null
          prev_stability?: number | null
          prev_state?: Database["public"]["Enums"]["card_state"] | null
          rating?: Database["public"]["Enums"]["review_rating"]
          reviewed_at?: string
          scheduled_days?: number | null
          session_id?: string | null
          time_spent_ms?: number | null
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "review_logs_card_id_fkey"
            columns: ["card_id"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["id"]
          },
        ]
      }
      socratic_remediation_sessions: {
        Row: {
          card_id: string
          chat_history: Json
          created_at: string
          id: string
          status: Database["public"]["Enums"]["job_status_type"]
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          card_id: string
          chat_history?: Json
          created_at?: string
          id?: string
          status?: Database["public"]["Enums"]["job_status_type"]
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          card_id?: string
          chat_history?: Json
          created_at?: string
          id?: string
          status?: Database["public"]["Enums"]["job_status_type"]
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "socratic_remediation_sessions_card_id_fkey"
            columns: ["card_id"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["id"]
          },
        ]
      }
      study_settings: {
        Row: {
          algorithm: Database["public"]["Enums"]["srs_algorithm"]
          created_at: string
          day_start_hour: number
          easy_interval_days: number
          fsrs_desired_retention: number
          fsrs_last_optimized_at: string | null
          fsrs_maximum_interval_days: number
          fsrs_optimizer_threshold: number
          fsrs_params: Json
          fsrs_version: string
          fsrs_weights: number[]
          graduating_interval_days: number
          learning_steps_minutes: number[]
          max_reviews_per_day: number
          new_cards_per_day: number
          relearning_steps_minutes: number[]
          starting_ease: number
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          created_at?: string
          day_start_hour?: number
          easy_interval_days?: number
          fsrs_desired_retention?: number
          fsrs_last_optimized_at?: string | null
          fsrs_maximum_interval_days?: number
          fsrs_optimizer_threshold?: number
          fsrs_params?: Json
          fsrs_version?: string
          fsrs_weights?: number[]
          graduating_interval_days?: number
          learning_steps_minutes?: number[]
          max_reviews_per_day?: number
          new_cards_per_day?: number
          relearning_steps_minutes?: number[]
          starting_ease?: number
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          created_at?: string
          day_start_hour?: number
          easy_interval_days?: number
          fsrs_desired_retention?: number
          fsrs_last_optimized_at?: string | null
          fsrs_maximum_interval_days?: number
          fsrs_optimizer_threshold?: number
          fsrs_params?: Json
          fsrs_version?: string
          fsrs_weights?: number[]
          graduating_interval_days?: number
          learning_steps_minutes?: number[]
          max_reviews_per_day?: number
          new_cards_per_day?: number
          relearning_steps_minutes?: number[]
          starting_ease?: number
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      tags: {
        Row: {
          color: string | null
          created_at: string
          id: string
          name: string
          user_id: string
          usn: number
        }
        Insert: {
          color?: string | null
          created_at?: string
          id?: string
          name: string
          user_id: string
          usn?: number
        }
        Update: {
          color?: string | null
          created_at?: string
          id?: string
          name?: string
          user_id?: string
          usn?: number
        }
        Relationships: []
      }
      user_badges: {
        Row: {
          badge_id: string
          id: string
          unlocked_at: string
          user_id: string
          usn: number
        }
        Insert: {
          badge_id: string
          id?: string
          unlocked_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          badge_id?: string
          id?: string
          unlocked_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "user_badges_badge_id_fkey"
            columns: ["badge_id"]
            isOneToOne: false
            referencedRelation: "badges_definition"
            referencedColumns: ["id"]
          },
        ]
      }
      user_deck_settings: {
        Row: {
          created_at: string
          deck_id: string
          display_order: number | null
          is_favorite: boolean
          overrides: Json
          updated_at: string
          user_id: string
          usn: number
        }
        Insert: {
          created_at?: string
          deck_id: string
          display_order?: number | null
          is_favorite?: boolean
          overrides?: Json
          updated_at?: string
          user_id: string
          usn?: number
        }
        Update: {
          created_at?: string
          deck_id?: string
          display_order?: number | null
          is_favorite?: boolean
          overrides?: Json
          updated_at?: string
          user_id?: string
          usn?: number
        }
        Relationships: [
          {
            foreignKeyName: "user_deck_settings_deck_id_fkey"
            columns: ["deck_id"]
            isOneToOne: false
            referencedRelation: "decks"
            referencedColumns: ["id"]
          },
        ]
      }
      user_function_rate_limits: {
        Row: {
          function_name: string
          request_count: number
          user_id: string
          window_started_at: string
        }
        Insert: {
          function_name: string
          request_count?: number
          user_id: string
          window_started_at: string
        }
        Update: {
          function_name?: string
          request_count?: number
          user_id?: string
          window_started_at?: string
        }
        Relationships: []
      }
      user_gamification_profiles: {
        Row: {
          created_at: string
          highest_streak_count: number
          level_current: number
          streak_days_count: number
          updated_at: string
          user_id: string
          usn: number
          xp_total: number
        }
        Insert: {
          created_at?: string
          highest_streak_count?: number
          level_current?: number
          streak_days_count?: number
          updated_at?: string
          user_id: string
          usn?: number
          xp_total?: number
        }
        Update: {
          created_at?: string
          highest_streak_count?: number
          level_current?: number
          streak_days_count?: number
          updated_at?: string
          user_id?: string
          usn?: number
          xp_total?: number
        }
        Relationships: []
      }
    }
    Views: {
      v_deck_tree: {
        Row: {
          depth: number | null
          id: string | null
          name: string | null
          parent_deck_id: string | null
          path: string | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      add_user_xp: {
        Args: { p_user_id: string; p_xp_amount: number }
        Returns: {
          created_at: string
          highest_streak_count: number
          level_current: number
          streak_days_count: number
          updated_at: string
          user_id: string
          usn: number
          xp_total: number
        }
        SetofOptions: {
          from: "*"
          to: "user_gamification_profiles"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      claim_fsrs_optimization_job: {
        Args: { p_run_id?: string }
        Returns: {
          completed_at: string | null
          error_message: string | null
          id: string
          new_loss: number | null
          new_weights: number[]
          old_loss: number | null
          old_weights: number[]
          requested_at: string
          source_review_count: number
          started_at: string | null
          status: string
          user_id: string
          usn: number
        }[]
        SetofOptions: {
          from: "*"
          to: "fsrs_optimization_runs"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      claim_fsrs_optimization_job_for_worker: {
        Args: { p_run_id: string }
        Returns: {
          completed_at: string | null
          error_message: string | null
          id: string
          new_loss: number | null
          new_weights: number[]
          old_loss: number | null
          old_weights: number[]
          requested_at: string
          source_review_count: number
          started_at: string | null
          status: string
          user_id: string
          usn: number
        }[]
        SetofOptions: {
          from: "*"
          to: "fsrs_optimization_runs"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      complete_fsrs_optimization_job: {
        Args: {
          p_new_loss?: number
          p_new_weights: number[]
          p_old_loss?: number
          p_run_id: string
        }
        Returns: undefined
      }
      complete_fsrs_optimization_job_for_worker: {
        Args: {
          p_new_loss?: number
          p_new_weights: number[]
          p_old_loss?: number
          p_run_id: string
          p_user_id: string
        }
        Returns: undefined
      }
      consume_user_rate_limit: {
        Args: {
          p_function_name: string
          p_limit?: number
          p_window_seconds?: number
        }
        Returns: {
          allowed: boolean
          retry_after_seconds: number
        }[]
      }
      create_anki_transfer_job: {
        Args: {
          p_direction: string
          p_file_sha256?: string
          p_options?: Json
          p_source_deck_id?: string
          p_storage_path: string
          p_target_deck_id?: string
        }
        Returns: string
      }
      create_image_occlusion_note: {
        Args: { p_boxes: Json; p_note_id: string }
        Returns: {
          card_id: string
          cloze_ordinal: number
        }[]
      }
      enqueue_fsrs_optimization: { Args: never; Returns: string }
      fail_fsrs_optimization_job: {
        Args: { p_error_message: string; p_run_id: string }
        Returns: undefined
      }
      fail_fsrs_optimization_job_for_worker: {
        Args: { p_error_message: string; p_run_id: string; p_user_id: string }
        Returns: undefined
      }
      find_similar_notes: {
        Args: {
          p_limit?: number
          p_match_threshold?: number
          p_note_id: string
        }
        Returns: {
          deck_id: string
          fields: Json
          note_id: string
          similarity: number
        }[]
      }
      get_current_streak: { Args: never; Returns: number }
      get_due_cards: {
        Args: { p_deck_id?: string; p_limit?: number }
        Returns: {
          card_id: string
          deck_id: string
          due_at: string
          fields: Json
          interval_days: number
          state: Database["public"]["Enums"]["card_state"]
        }[]
      }
      get_due_cards_with_exam_schedule: {
        Args: { p_deck_id?: string; p_limit?: number }
        Returns: {
          card_id: string
          days_remaining: number
          deck_id: string
          due_at: string
          exam_id: string
          exam_name: string
          fields: Json
          interval_days: number
          scheduling_factor: number
          state: Database["public"]["Enums"]["card_state"]
          target_date: string
        }[]
      }
      get_fsrs_optimization_status: {
        Args: never
        Returns: {
          has_queued_run: boolean
          is_ready: boolean
          last_optimized_at: string
          optimizer_threshold: number
          review_count: number
        }[]
      }
      get_incremental_sync: {
        Args: { p_after_usn?: number; p_limit?: number }
        Returns: {
          entity_key: string
          entity_type: string
          is_deleted: boolean
          payload: Json
          usn: number
        }[]
      }
      list_orphaned_card_media: {
        Args: { p_limit?: number }
        Returns: {
          media_id: string
          storage_bucket: string
          storage_path: string
        }[]
      }
      mcp_create_note: {
        Args: {
          p_card_definitions?: Json
          p_content_hash?: string
          p_deck_id: string
          p_external_id?: string
          p_fields: Json
          p_request_id?: string
          p_source?: string
          p_template_id?: string
        }
        Returns: {
          card_ids: string[]
          note_id: string
        }[]
      }
      mcp_search_notes: {
        Args: {
          p_limit?: number
          p_query: string
          p_query_embedding?: string
          p_request_id?: string
        }
        Returns: {
          deck_id: string
          fields: Json
          match_type: string
          note_id: string
          similarity: number
        }[]
      }
      record_review: {
        Args: {
          p_algorithm?: Database["public"]["Enums"]["srs_algorithm"]
          p_card_id: string
          p_device_id?: string
          p_new_difficulty?: number
          p_new_due_at: string
          p_new_ease_factor?: number
          p_new_interval_days: number
          p_new_stability?: number
          p_new_state: Database["public"]["Enums"]["card_state"]
          p_rating: Database["public"]["Enums"]["review_rating"]
          p_session_id?: string
          p_time_spent_ms: number
        }
        Returns: undefined
      }
      record_review_fsrs6: {
        Args: {
          p_algorithm_state?: Json
          p_card_id: string
          p_device_id?: string
          p_elapsed_days: number
          p_fsrs_retrievability: number
          p_fsrs_state: number
          p_fsrs_step: number
          p_new_difficulty: number
          p_new_due_at: string
          p_new_interval_days: number
          p_new_stability: number
          p_new_state: Database["public"]["Enums"]["card_state"]
          p_parameter_version?: number
          p_rating: Database["public"]["Enums"]["review_rating"]
          p_scheduled_days: number
          p_session_id?: string
          p_time_spent_ms: number
        }
        Returns: undefined
      }
      record_review_fsrs6_idempotent: {
        Args: {
          p_algorithm_state: Json
          p_card_id: string
          p_client_review_id: string
          p_device_id: string
          p_elapsed_days: number
          p_expected_usn?: number
          p_fsrs_retrievability: number
          p_fsrs_state: number
          p_fsrs_step: number
          p_new_difficulty: number
          p_new_due_at: string
          p_new_interval_days: number
          p_new_stability: number
          p_new_state: Database["public"]["Enums"]["card_state"]
          p_parameter_version: number
          p_rating: Database["public"]["Enums"]["review_rating"]
          p_scheduled_days: number
          p_session_id: string
          p_time_spent_ms: number
        }
        Returns: string
      }
      resolve_socratic_remediation: {
        Args: { p_session_id: string }
        Returns: {
          card_id: string
          chat_history: Json
          created_at: string
          id: string
          status: Database["public"]["Enums"]["job_status_type"]
          updated_at: string
          user_id: string
          usn: number
        }
        SetofOptions: {
          from: "*"
          to: "socratic_remediation_sessions"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      search_notes_by_embedding: {
        Args: {
          p_limit?: number
          p_match_threshold?: number
          p_query_embedding: string
        }
        Returns: {
          deck_id: string
          fields: Json
          note_id: string
          similarity: number
        }[]
      }
      soft_delete_deck: { Args: { p_deck_id: string }; Returns: undefined }
    }
    Enums: {
      card_state: "new" | "learning" | "review" | "relearning"
      collaborator_role: "viewer" | "editor"
      deck_visibility: "private" | "shared" | "public"
      exam_priority_level:
        | "exam_urgent"
        | "currently_studying"
        | "maintaining"
        | "paused"
      generation_source_type:
        | "pdf_document"
        | "youtube_url"
        | "raw_text_block"
        | "web_page"
      job_status_type: "queued" | "processing" | "completed" | "failed"
      media_type: "image" | "audio" | "video" | "other"
      review_rating: "again" | "hard" | "good" | "easy"
      srs_algorithm: "sm2" | "fsrs" | "custom"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      card_state: ["new", "learning", "review", "relearning"],
      collaborator_role: ["viewer", "editor"],
      deck_visibility: ["private", "shared", "public"],
      exam_priority_level: [
        "exam_urgent",
        "currently_studying",
        "maintaining",
        "paused",
      ],
      generation_source_type: [
        "pdf_document",
        "youtube_url",
        "raw_text_block",
        "web_page",
      ],
      job_status_type: ["queued", "processing", "completed", "failed"],
      media_type: ["image", "audio", "video", "other"],
      review_rating: ["again", "hard", "good", "easy"],
      srs_algorithm: ["sm2", "fsrs", "custom"],
    },
  },
} as const
