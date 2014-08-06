class Devise::InvitationsController < DeviseController

  prepend_before_filter :authenticate_inviter!, :only => [:new, :create]
  prepend_before_filter :has_invitations_left?, :only => [:create]
  prepend_before_filter :require_no_authentication, :only => [:edit, :update, :destroy]
  prepend_before_filter :resource_from_invitation_token, :only => [:edit, :destroy]
  helper_method :after_sign_in_path_for

  # GET /resource/invitation/new
  def new
    @roles = Role.all
    @organizations = Organization.all
    @specialties = Specialty.all
    @users = User.order("id").all

    @my_role_id = 1
    @my_staff = nil
    @my_specialties = nil
    self.resource = resource_class.new
    render template: "master/users/invitations/new"

    # self.resource = resource_class.new
    # render :new
  end

  # POST /resource/invitation
  def create
    @result = validate_check(params)
    unless @result[0].present?
      self.resource = invite_resource
    else
      self.resource = User.new @result[1]
    end

    @result[0].each do |k, v|
      resource.errors.add k, v
    end

    if resource.errors.empty?
      # 権限の設定
      # role = user_role(params[:role])
      # if role.present?
      #   case role.id
      #   when Settings.role.mr
      #     self.resource.add_role :mr
      #   when Settings.role.doctor
      #     self.resource.add_role :doctor
      #   when Settings.role.nurse
      #     self.resource.add_role :nurse
      #   when Settings.role.master
      #     self.resource.add_role :mr
      #     self.resource.add_role :master
      #   end
      # end

      # 興味のある分野の設定
      if params[:specialties].present?
        params[:specialties].each do |specialty|
          specialty = Specialty.by_id(specialty[1].to_i).first
          if specialty.present?
            user_specialty = UserSpecialty.new user_id: self.resource.id, specialty_id: specialty.id
            user_specialty.save
          end
        end
      end

      # 担当MR設定
      if params[:conversation][:user_1].present?
        mr_user = User.by_id(params[:conversation][:user_1]).first
        if mr_user.present?
          conversation = Conversation.new user_1: mr_user.id, user_2: self.resource.id
          conversation.save
        end
      end

      yield resource if block_given?

      # MRと事務局は仮メールを送信しないため、tokenを削除する
      role = user_role(params[:role])
      if role.present? && (role.id.to_i == Settings.role.mr || role.id.to_i == Settings.role.master)
        self.resource.invitation_token = nil
        self.resource.save
      end
      set_flash_message :notice, :send_instructions, :email => self.resource.email if self.resource.invitation_sent_at
      respond_with resource, :location => master_users_path
    else
      @roles = Role.all
      @organizations = Organization.all
      @specialties = Specialty.all
      @users = User.order("id").all

      @my_role_id = params[:role]
      @my_staff = params[:conversation][:user_1]
      @my_specialties = params[:specialties]

      respond_with_navigational(resource) { render template: "master/users/invitations/new" }
    end

    # self.resource = invite_resource

    # if resource.errors.empty?
    #   yield resource if block_given?
    #   set_flash_message :notice, :send_instructions, :email => self.resource.email if self.resource.invitation_sent_at
    #   respond_with resource, :location => after_invite_path_for(resource)
    # else
    #   respond_with_navigational(resource) { render :new }
    # end
  end

  # GET /resource/invitation/accept?invitation_token=abcdef
  def edit
    resource.invitation_token = params[:invitation_token]
    render template: "master/users/invitations/edit"

    # resource.invitation_token = params[:invitation_token]
    # render :edit
  end

  # PUT /resource/invitation
  def update
    self.resource = accept_resource

    if resource.errors.empty?
      yield resource if block_given?
      flash_message = resource.active_for_authentication? ? :updated : :updated_not_active
      set_flash_message :notice, flash_message
      sign_in(resource_name, resource)
      respond_with resource, :location => after_accept_path_for(resource)
    else
      respond_with_navigational(resource){ render template: "master/users/invitations/edit" }
    end

    # self.resource = accept_resource

    # if resource.errors.empty?
    #   yield resource if block_given?
    #   flash_message = resource.active_for_authentication? ? :updated : :updated_not_active
    #   set_flash_message :notice, flash_message
    #   sign_in(resource_name, resource)
    #   respond_with resource, :location => after_accept_path_for(resource)
    # else
    #   respond_with_navigational(resource){ render :edit }
    # end
  end

  # GET /resource/invitation/remove?invitation_token=abcdef
  def destroy
    resource.destroy
    set_flash_message :notice, :invitation_removed
    redirect_to master_users_path

    # resource.destroy
    # set_flash_message :notice, :invitation_removed
    # redirect_to after_sign_out_path_for(resource_name)
  end

  private
  def validate_check(params)
    result = {
      email: params[:user][:email],
      avatar: params[:user][:avatar],
      remove_avatar: params[:user][:remove_avatar],
      family_name: params[:user][:family_name],
      first_name: params[:user][:first_name],
      organization_id: params[:user][:organization_id],
      memo: params[:user][:memo],
      sex: params[:user][:sex],
      college: params[:user][:college],
      graduation_year: params[:user][:graduation_year],
      password: params[:user][:password],
      password_confirmation: params[:user][:password_confirmation]
    }

    # modelのバリデーションが効かないため個々に対応
    errors = {}
    if params[:user][:email].present?
      user = User.new
      if user.deleted_create?(params[:user][:email])
        errors[:email] = "はすでに存在します。"
      end
    else
      errors[:email] = "を入力してください。"
    end

    unless params[:user][:family_name].present?
      errors[:family_name] = "を入力してください。"
    end

    unless params[:user][:first_name].present?
      errors[:first_name] = "を入力してください。"
    end

    # 正しい日付で設定されているか
    birth_day_year = params[:user][:birth_day_year]
    birth_day_month = params[:user][:birth_day_month]
    birth_day_day = params[:user][:birth_day_day]
    if birth_day_year.present? || birth_day_month.present? || birth_day_month.present?
      if Date.valid_date?(birth_day_year.to_i, birth_day_month.to_i, birth_day_day.to_i)

        birth_day = Date.new(birth_day_year.to_i, birth_day_month.to_i, birth_day_day.to_i)
        result[:birth_day] = birth_day
        if Date.today < birth_day
          errors[:birth_day] = "生年月日を未来日で設定することはできません。"
        end
      else
        errors[:birth_day] = "正しい日付を入力してください。"
      end
    else
      result[:birth_day] = nil
    end

    role = user_role(params[:role])
    # MR、D-mae事務局はパスワード必須
    if role.present? && (role.id.to_i == Settings.role.mr || role.id.to_i == Settings.role.master)
      unless params[:user][:password].present?
        errors[:password] = "パスワードを入力してください。"
      end

      if params[:user][:password].present?
        if params[:user][:password].size < 8
          errors[:password] = "パスワードは8文字以上で入力してください。"
        elsif params[:user][:password].size > 128
          errors[:password] = "パスワードは128文字以内で入力してください。"
        end
      end

      if (params[:user][:password].present? || params[:user][:password_confirmation].present?) && params[:user][:password] != params[:user][:password_confirmation]
        errors[:password_confirmation] = "パスワードと確認の入力が一致しません。"
      end
    end

    # 医師、看護師は担当MRが必ず存在している
    if role.present? && (role.id.to_i == Settings.role.doctor || role.id.to_i == Settings.role.nurse)
      if params[:conversation][:user_1].present?
        staff = User.by_id(params[:conversation][:user_1]).first
        unless staff.present?
          errors[:conversation_user_1] = "担当MRが削除された可能性があります。"
        end
      else
        errors[:conversation_user_1] = "担当MRを設定してください。"
      end
    end

    [errors, result]
  end

  # ユーザ種別情報取得
  def user_role(role_id)
    Role.by_id(role_id).first
  end

  def invite_resource()
    resource_class.invite!(@result[1], current_inviter, params)
    # resource_class.invite!(@result[1], current_inviter) do |u|
    #   role = user_role(params[:role])
    #   if role.present? && (role.id.to_i == Settings.role.mr || role.id.to_i == Settings.role.master)
    #     u.skip_invitation = true
    #   end
    # end
  end

  protected

  # def invite_resource(&block)
  #   resource_class.invite!(invite_params, current_inviter, &block)
  # end

  def accept_resource
    resource_class.accept_invitation!(update_resource_params)
  end

  def current_inviter
    authenticate_inviter!
  end

  def has_invitations_left?
    unless current_inviter.nil? || current_inviter.has_invitations_left?
      self.resource = resource_class.new
      set_flash_message :alert, :no_invitations_remaining
      respond_with_navigational(resource) { render :new }
    end
  end

  def resource_from_invitation_token
    unless params[:invitation_token] && self.resource = resource_class.find_by_invitation_token(params[:invitation_token], true)
      set_flash_message(:alert, :invitation_token_invalid)
      redirect_to after_sign_out_path_for(resource_name)
    end
  end

  def invite_params
    devise_parameter_sanitizer.sanitize(:invite)
  end

  def update_resource_params
    devise_parameter_sanitizer.sanitize(:accept_invitation)
  end

  # override
  def devise_mapping
    @devise_mapping ||= Devise.mappings[:user]#request.env["devise.mapping"]
  end
end

