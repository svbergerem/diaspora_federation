module DiasporaFederation
  describe Entities::Participation do
    let(:parent) { FactoryGirl.create(:post, author: bob) }
    let(:parent_entity) { FactoryGirl.build(:related_entity, author: bob.diaspora_id) }
    let(:data) {
      FactoryGirl.build(
        :participation_entity,
        author:      alice.diaspora_id,
        parent_guid: parent.guid,
        parent_type: parent.entity_type,
        parent:      parent_entity
      ).send(:xml_elements).merge(parent: parent_entity)
    }

    let(:xml) {
      <<-XML
<participation>
  <guid>#{data[:guid]}</guid>
  <target_type>#{parent.entity_type}</target_type>
  <parent_guid>#{parent.guid}</parent_guid>
  <diaspora_handle>#{data[:author]}</diaspora_handle>
  <author_signature>#{data[:author_signature]}</author_signature>
  <parent_author_signature>#{data[:parent_author_signature]}</parent_author_signature>
</participation>
XML
    }

    it_behaves_like "an Entity subclass", [:parent]

    it_behaves_like "an XML Entity"

    it_behaves_like "a relayable Entity"

    describe "#parent_type" do
      it "returns data[:parent_type] as parent type" do
        expect(described_class.new(data).parent_type).to eq(data[:parent_type])
      end
    end
  end
end
