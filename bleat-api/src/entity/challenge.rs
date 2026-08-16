use sea_orm::entity::prelude::*;

#[derive(Clone, Debug, PartialEq, DeriveEntityModel)]
#[sea_orm(table_name = "challenges")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub id: Uuid,
    pub digest: Vec<u8>,
    pub purpose: String,
    pub installation_id: Option<Uuid>,
    pub expires_at: DateTimeUtc,
    pub consumed_at: Option<DateTimeUtc>,
    pub created_at: DateTimeUtc,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {
    #[sea_orm(
        belongs_to = "super::installation::Entity",
        from = "Column::InstallationId",
        to = "super::installation::Column::Id",
        on_update = "NoAction",
        on_delete = "Cascade"
    )]
    Installation,
}

impl Related<super::installation::Entity> for Entity {
    fn to() -> RelationDef {
        Relation::Installation.def()
    }
}

impl ActiveModelBehavior for ActiveModel {}
